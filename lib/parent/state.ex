defmodule Parent.State do
  @moduledoc false

  alias Parent.RestartCounter

  @opaque t :: %{
            opts: Parent.opts(),
            id_to_pid: %{Parent.child_id() => pid},
            children: %{pid => child()},
            startup_index: non_neg_integer,
            restart_counter: RestartCounter.t(),
            shutdown_groups: %{Parent.shutdown_group() => MapSet.t(Parent.child_id())},
            registry?: boolean
          }

  @type child :: %{
          spec: Parent.child_spec(),
          pid: pid,
          timer_ref: reference() | nil,
          startup_index: non_neg_integer(),
          dependencies: MapSet.t(Parent.child_id()),
          bound_siblings: MapSet.t(Parent.child_id()),
          restart_counter: RestartCounter.t(),
          meta: Parent.child_meta()
        }

  @type filter :: [{:id, Parent.child_id()}] | [{:pid, pid}]

  @spec initialize(Parent.opts()) :: t
  def initialize(opts) do
    opts = Keyword.merge([max_restarts: 3, max_seconds: 5, registry?: false], opts)

    %{
      opts: opts,
      id_to_pid: %{},
      children: %{},
      startup_index: 0,
      restart_counter: RestartCounter.new(opts[:max_restarts], opts[:max_seconds]),
      shutdown_groups: %{},
      registry?: Keyword.fetch!(opts, :registry?)
    }
  end

  @spec reinitialize(t) :: t
  def reinitialize(state), do: %{initialize(state.opts) | startup_index: state.startup_index}

  @spec registry?(t) :: boolean
  def registry?(state), do: state.registry?

  @spec register_child(t, pid, Parent.child_spec(), reference | nil) :: t
  def register_child(state, pid, spec, timer_ref) do
    false = Map.has_key?(state.children, pid)
    false = Map.has_key?(state.id_to_pid, spec.id)

    {dependencies, state} = update_dependencies(state, spec)

    child = %{
      spec: spec,
      pid: pid,
      timer_ref: timer_ref,
      startup_index: state.startup_index,
      dependencies: dependencies,
      bound_siblings: MapSet.new(),
      restart_counter: RestartCounter.new(spec.max_restarts, spec.max_seconds),
      meta: spec.meta
    }

    state
    |> put_in([:id_to_pid, spec.id], pid)
    |> put_in([:children, pid], child)
    |> add_to_shutdown_group(spec)
    |> Map.update!(:startup_index, &(&1 + 1))
  end

  @spec register_child(t, pid, child, reference | nil) :: t
  def reregister_child(state, child, pid, timer_ref) do
    false = Map.has_key?(state.children, pid)
    false = Map.has_key?(state.id_to_pid, child.spec.id)

    {dependencies, state} = update_dependencies(state, child.spec)

    child = %{
      child
      | pid: pid,
        timer_ref: timer_ref,
        dependencies: dependencies,
        bound_siblings: MapSet.new(),
        meta: child.spec.meta
    }

    state
    |> put_in([:id_to_pid, child.spec.id], child.pid)
    |> put_in([:children, child.pid], child)
    |> add_to_shutdown_group(child.spec)
  end

  @spec children(t) :: [child()]
  def children(state) do
    state.children
    |> Map.values()
    |> Enum.sort_by(& &1.startup_index)
  end

  @spec children_in_shutdown_group(t, Parent.shutdown_group()) :: [child]
  def children_in_shutdown_group(state, shutdown_group) do
    state.shutdown_groups
    |> Map.get(shutdown_group, [])
    |> Enum.map(&child!(state, id: &1))
  end

  @spec record_restart(t) :: {:ok, t} | :error
  def record_restart(state) do
    with {:ok, counter} <- RestartCounter.record_restart(state.restart_counter),
         do: {:ok, %{state | restart_counter: counter}}
  end

  @spec pop_child_with_bound_siblings(t, filter) :: {:ok, [child], t} | :error
  def pop_child_with_bound_siblings(state, filter) do
    with {:ok, child} <- child(state, filter) do
      {children, state} = pop_child_and_bound_children(state, pid: child.pid)
      {:ok, children, state}
    end
  end

  @spec num_children(t) :: non_neg_integer
  def num_children(state), do: Enum.count(state.children)

  @spec child(t, filter) :: {:ok, child} | :error
  def child(state, id: id),
    do: with({:ok, pid} <- child_pid(state, id), do: child(state, pid: pid))

  def child(state, pid: pid), do: Map.fetch(state.children, pid)

  @spec child?(t, filter) :: boolean()
  def child?(state, filter), do: match?({:ok, _child}, child(state, filter))

  @spec child!(t, filter) :: child
  def child!(state, filter) do
    {:ok, child} = child(state, filter)
    child
  end

  @spec child_id(t, pid) :: {:ok, Parent.child_id()} | :error
  def child_id(state, pid) do
    with {:ok, child} <- Map.fetch(state.children, pid), do: {:ok, child.spec.id}
  end

  @spec child_pid(t, Parent.child_id()) :: {:ok, pid} | :error
  def child_pid(state, id), do: Map.fetch(state.id_to_pid, id)

  @spec child_meta(t, Parent.child_id()) :: {:ok, Parent.child_meta()} | :error
  def child_meta(state, id) do
    with {:ok, pid} <- child_pid(state, id),
         {:ok, child} <- Map.fetch(state.children, pid),
         do: {:ok, child.meta}
  end

  @spec update_child_meta(t, Parent.child_id(), (Parent.child_meta() -> Parent.child_meta())) ::
          {:ok, Parent.child_meta(), t} | :error
  def update_child_meta(state, id, updater) do
    with {:ok, child, state} <- update(state, [id: id], &update_in(&1.meta, updater)),
         do: {:ok, child.meta, state}
  end

  defp update(state, filter, updater) do
    with {:ok, child} <- child(state, filter),
         updated_child = updater.(child),
         updated_children = Map.put(state.children, child.pid, updated_child),
         do: {:ok, updated_child, %{state | children: updated_children}}
  end

  defp update!(state, filter, updater) do
    {:ok, _child, state} = update(state, filter, updater)
    state
  end

  defp update_dependencies(state, spec) do
    dependencies =
      Enum.reduce(
        spec.binds_to,
        MapSet.new(spec.binds_to),
        &MapSet.union(&2, child!(state, id: &1).dependencies)
      )

    state =
      Enum.reduce(
        dependencies,
        state,
        fn dep_id, state ->
          update!(state, [id: dep_id], fn dep ->
            update_in(dep.bound_siblings, &MapSet.put(&1, spec.id))
          end)
        end
      )

    {dependencies, state}
  end

  defp pop_child_and_bound_children(state, filter) do
    child = child!(state, filter)
    children = Map.values(all_bound_children(state, child, %{child.spec.id => child}))
    state = Enum.reduce(children, state, &remove_child(&2, &1.spec.id))
    {Enum.sort_by(children, & &1.startup_index), state}
  end

  defp all_bound_children(state, child, deps) do
    state.shutdown_groups
    |> Map.get(child.spec.shutdown_group, [])
    |> Stream.concat(child.bound_siblings)
    |> Stream.uniq()
    |> Stream.map(&child!(state, id: &1))
    |> Enum.reduce(deps, fn dep, deps ->
      if Map.has_key?(deps, dep.spec.id),
        do: deps,
        else: all_bound_children(state, dep, Map.put(deps, dep.spec.id, dep))
    end)
  end

  defp remove_child(state, child_id) do
    child = child!(state, id: child_id)

    state =
      state
      |> Map.update!(:id_to_pid, &Map.delete(&1, child.spec.id))
      |> Map.update!(:children, &Map.delete(&1, child.pid))
      |> remove_from_shutdown_group(child.spec)

    state =
      Enum.reduce(
        child.dependencies,
        state,
        fn dep_id, state ->
          update!(state, [id: dep_id], fn dep ->
            update_in(dep.bound_siblings, &MapSet.delete(&1, child.spec.id))
          end)
        end
      )

    Enum.reduce(
      child.bound_siblings,
      state,
      fn bound_sibling_id, state ->
        update!(state, [id: bound_sibling_id], fn bound_sibling ->
          update_in(bound_sibling.dependencies, &MapSet.delete(&1, child.spec.id))
        end)
      end
    )
  end

  defp add_to_shutdown_group(state, %{shutdown_group: nil}), do: state

  defp add_to_shutdown_group(state, spec) do
    state
    |> Map.update!(:shutdown_groups, &Map.put_new(&1, spec.shutdown_group, MapSet.new()))
    |> update_in([:shutdown_groups, spec.shutdown_group], &MapSet.put(&1, spec.id))
  end

  defp remove_from_shutdown_group(state, %{shutdown_group: nil}), do: state

  defp remove_from_shutdown_group(state, spec),
    do: update_in(state.shutdown_groups[spec.shutdown_group], &MapSet.delete(&1, spec.id))
end
