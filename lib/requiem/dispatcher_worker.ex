defmodule Requiem.DispatcherWorker do
  require Logger
  require Requiem.Tracer
  use GenServer

  alias Requiem.Address
  alias Requiem.Connection
  alias Requiem.ConnectionID
  alias Requiem.ConnectionSupervisor
  alias Requiem.DispatcherRegistry
  alias Requiem.SenderRegistry
  alias Requiem.SenderWorker
  alias Requiem.NIF
  alias Requiem.RetryToken
  alias Requiem.Tracer

  @type t :: %__MODULE__{
          handler: module,
          token_secret: binary,
          conn_id_secret: binary,
          worker_index: non_neg_integer,
          number_of_sockets: non_neg_integer,
          config_ptr: integer,
          sender_pid: pid,
          packet_builder: integer,
          trace_id: binary
        }

  defstruct handler: nil,
            token_secret: "",
            conn_id_secret: "",
            worker_index: 0,
            number_of_sockets: 0,
            config_ptr: 0,
            sender_pid: nil,
            packet_builder: 0,
            trace_id: ""

  @spec child_spec(Keyword.t()) :: map
  def child_spec(opts) do
    handler = Keyword.fetch!(opts, :handler)
    index = Keyword.fetch!(opts, :worker_index)

    %{
      id: name(handler, index),
      start: {__MODULE__, :start_link, [opts]},
      shutdown: 5_000,
      restart: :permanent,
      type: :worker
    }
  end

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    handler = Keyword.fetch!(opts, :handler)
    index = Keyword.fetch!(opts, :worker_index)
    GenServer.start_link(__MODULE__, opts, name: name(handler, index))
  end

  @impl GenServer
  def init(opts) do
    state = new(opts)

    sender_idx = rem(state.worker_index, state.number_of_sockets)
    {:ok, sender_pid} = SenderRegistry.lookup(state.handler, sender_idx)
    state = %{state | sender_pid: sender_pid}

    {:ok, config} = NIF.Config.new()

    try do
      NIF.init_config(state.handler, config)
    rescue
      err ->
        NIF.Config.destroy(config)
        raise err
    end

    Process.flag(:trap_exit, true)

    case DispatcherRegistry.register(
           state.handler,
           state.worker_index
         ) do
      {:ok, _pid} ->
        {:ok, builder} = NIF.PacketBuilder.new()
        {:ok, %{state | packet_builder: builder, config_ptr: config}}

      {:error, {:already_registered, _pid}} ->
        NIF.Config.destroy(config)
        {:stop, :normal}
    end
  end

  @impl GenServer
  def handle_info(
        {:__packet__, peer, packet, scid, dcid, token, version, packet_type,
         is_version_supported},
        state
      ) do
    # this come from native receiver socket
    address = Address.from_rust_peer(peer)
    Tracer.trace(__MODULE__, state.trace_id, "@received: #{address}")

    process_packet(
      address,
      packet,
      scid,
      dcid,
      token,
      version,
      packet_type,
      is_version_supported,
      state
    )

    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    DispatcherRegistry.unregister(state.handler, state.worker_index)
    NIF.Config.destroy(state.config_ptr)
    NIF.PacketBuilder.destroy(state.packet_builder)
    :ok
  end

  defp process_packet(address, _packet, scid, dcid, _token, _version, :initial, false, state) do
    Tracer.trace(__MODULE__, state.trace_id, "@unsupported_version")
    handle_version_unsupported_packet(address, scid, dcid, state)
    :ok
  end

  defp process_packet(address, packet, scid, dcid, token, version, :initial, true, state) do
    Tracer.trace(__MODULE__, state.trace_id, "@init")
    handle_init_packet(address, packet, scid, dcid, token, version, state)
    :ok
  end

  defp process_packet(
         address,
         packet,
         scid,
         dcid,
         _token,
         _version,
         packet_type,
         _version_supported,
         state
       ) do
    Tracer.trace(__MODULE__, state.trace_id, "@regular: #{packet_type}")
    handle_regular_packet(address, packet, scid, dcid, state)
    :ok
  end

  defp new(opts) do
    %__MODULE__{
      handler: Keyword.fetch!(opts, :handler),
      worker_index: Keyword.fetch!(opts, :worker_index),
      number_of_sockets: Keyword.fetch!(opts, :number_of_sockets),
      token_secret: Keyword.fetch!(opts, :token_secret),
      conn_id_secret: Keyword.fetch!(opts, :conn_id_secret),
      config_ptr: 0,
      trace_id: inspect(self())
    }
  end

  defp send(address, packet, %__MODULE__{sender_pid: sender_pid}) do
    SenderWorker.send(sender_pid, address, packet)
    :ok
  end

  defp handle_regular_packet(address, packet, _scid, dcid, state)
       when byte_size(dcid) == 20 or byte_size(dcid) == 0 do
    case ConnectionSupervisor.lookup_connection(
           state.handler,
           dcid
         ) do
      {:ok, pid} ->
        Connection.process_packet(pid, address, packet)

      {:error, :not_found} ->
        :error
    end
  end

  defp handle_regular_packet(_address, _packet, _scid, _dcid, state) do
    Tracer.trace(__MODULE__, state.trace_id, "@regular: bad dcid")
    :ok
  end

  defp handle_version_unsupported_packet(address, scid, dcid, state) do
    case NIF.PacketBuilder.build_negotiate_version(state.packet_builder, scid, dcid) do
      {:ok, resp} ->
        send(address, resp, state)
        :ok

      error ->
        error
    end
  end

  defp handle_token_missing_packet(address, scid, dcid, version, state) do
    with {:ok, new_id} <-
           ConnectionID.generate_from_odcid(state.conn_id_secret, dcid),
         {:ok, token} <-
           RetryToken.create(address, dcid, new_id, state.token_secret),
         {:ok, resp} <-
           NIF.PacketBuilder.build_retry(
             state.packet_builder,
             scid,
             dcid,
             new_id,
             token,
             version
           ) do
      Tracer.trace(__MODULE__, state.trace_id, "@send")
      send(address, resp, state)
      :ok
    else
      {:error, _reason} -> :error
      :error -> :error
    end
  end

  defp handle_retry_packet(address, packet, scid, dcid, token, state)
       when byte_size(dcid) == 20 do
    Tracer.trace(__MODULE__, state.trace_id, "@validate")

    case RetryToken.validate(address, dcid, state.token_secret, token) do
      {:ok, odcid} ->
        Tracer.trace(__MODULE__, state.trace_id, "@validate_success")

        case create_connection_if_needed(
               address,
               scid,
               dcid,
               odcid,
               state
             ) do
          :ok ->
            handle_regular_packet(address, packet, scid, dcid, state)

          {:error, :system_error} ->
            :error
        end

        {:error, :system_error}
        :error
    end
  end

  defp handle_retry_packet(_address, _packet, _scid, _dcid, _token, state) do
    Tracer.trace(__MODULE__, state.trace_id, "@validate: bad dcid")
    :error
  end

  defp handle_init_packet(address, packet, scid, dcid, token, version, state) do
    case ConnectionSupervisor.lookup_connection(
           state.handler,
           dcid
         ) do
      {:ok, pid} ->
        Connection.process_packet(pid, address, packet)

      {:error, :not_found} ->
        if token == "" do
          Tracer.trace(__MODULE__, state.trace_id, "@token_missing_packet")
          handle_token_missing_packet(address, scid, dcid, version, state)
        else
          Tracer.trace(__MODULE__, state.trace_id, "@retry_packet")
          handle_retry_packet(address, packet, scid, dcid, token, state)
        end
    end
  end

  defp create_connection_if_needed(_address, _scid, <<>>, _odcid, _state) do
    :ok
  end

  defp create_connection_if_needed(address, scid, dcid, odcid, state) do
    ConnectionSupervisor.create_connection(
      state.handler,
      address,
      scid,
      dcid,
      odcid,
      state.config_ptr,
      state.sender_pid
    )
  end

  defp name(handler, index),
    do: Module.concat([handler, __MODULE__, "Worker_#{index}"])
end
