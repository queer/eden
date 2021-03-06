defmodule Eden do
  @moduledoc """
  Adapted heavily from http://teamon.eu/2017/setting-up-elixir-cluster-using-docker-and-rancher/

  Basically, the idea is to have a generic lib. to store Elixir process info in
  etcd to use for distributed Elixir node discovery. 

  Example use:

      children = [
        # ...
        worker(Eden, ["service_name"], shutdown: 123_456)
      ]
  """

  use GenServer

  alias Eden.Platform

  require Logger

  # Attempt to connect to new nodes every 5 seconds. 
  # TODO: Make this configurable?
  @connect_interval 5000

  def start_link() do
    GenServer.start_link __MODULE__, :ok, name: __MODULE__
  end

  def init(:ok) do
    # Trap exits so we can respond
    Process.flag :trap_exit, true

    # Expect just a name as input
    hash = :crypto.hash(:md5, :os.system_time(:millisecond) 
                              |> Integer.to_string) 
                              |> Base.encode16 
                              |> String.downcase
    node_fullname = System.get_env("NODE_NAME")

    Logger.info "Node type: #{node_fullname}"
    Logger.info "Node hash: #{hash}"

    state = %{
              shortname: node_fullname,
              name: "#{node_fullname}-#{hash}",
              hash: hash,
              registry_dir: "eden_registry_" <> to_string(node_fullname)
            }

    
    hostname_ip = Platform.hostname_with_ip()
    unless Node.alive? do
      {:ok, _} = Node.start(:"#{state[:name]}@#{hostname_ip[:hostaddr]}", :longnames)
      Node.set_cookie(System.get_env("COOKIE") |> String.to_atom)
    else
      Logger.warn "Node already alive (distillery?), not initializing..."
    end

    # Start it up!
    send self(), :connect

    {:ok, state}
  end

  def handle_call(:get_hash, _from, state) do
    {:reply, state[:hash], state}
  end

  def handle_info(:connect, state) do
    dir_name = state[:registry_dir]

    # Note: This does re-set the key each time the :connect call is handled.
    # The justification for this is that, if the etcd cluster loses the info
    # for whatever reason, we can try and recover ourselves from it

    # Ensure the registry even exists
    registry = Violet.list_dir dir_name
    if is_nil registry do
      Logger.warn "Etcd registry doesn't exist, doing initial setup..."
      Violet.make_dir dir_name
    end

    # Register ourselves
    # We don't need to care about the hostname, so we just map the hash to the
    # hostaddr
    hostname_ip = Platform.hostname_with_ip()
    Violet.set dir_name, state[:hash], hostname_ip[:hostaddr]

    # Start connecting
    unless is_nil registry do
      for node_info <- registry do
        # Logger.info "Node: #{inspect node_info}"
        node_hash = node_info["key"] |> String.split("/") |> List.last
        node_ip = node_info["value"]
        node_fullname = "#{state[:shortname]}-#{node_hash}"
        node_atom = :"#{node_fullname}@#{node_ip}"
        #Logger.info "Connecting to #{inspect node_atom} identified by #{inspect node_hash}"
        # Don't worry about connecting to ourselves because it's handled for us
        case Node.connect node_atom do
          true -> Logger.debug "Connected to #{inspect node_atom}"
          # This is fine because if the node is still alive, we can just remove it and try
          # again next run if it's brought itself back up
          false -> delete_node node_info["key"], node_hash, state[:hash]
          :ignored -> Logger.warn "Local node is not alive for node #{inspect node_atom}!?"
        end
      end

      Logger.info "Eden is connected to the following nodes: #{inspect Node.list}"
    end

    # Handle reconnects etc.
    Process.send_after self(), :connect, @connect_interval

    {:noreply, state}
  end

  defp delete_node(key, node_hash, self_hash) do
    if node_hash != self_hash do
      Logger.warn "Cleaning dead node: #{inspect node_hash}"
      Violet.delete key
    end
  end

  def terminate(reason, state) do
    # Clean ourselves from the etcd registry
    Logger.error "Eden GenServer terminating, cleaning self from registry..."
    Logger.error "Termination reason: #{inspect reason}"
    Violet.delete state[:registry_dir], state[:hash]
  end

  def fanout_exec(tasks_module, module, atom, args) do
    for node <- Node.list do
      {tasks_module, node}
      |> Task.Supervisor.async(module, atom, args)
      |> Task.await
    end

    apply(module, atom, args)

    :ok
  end
end
