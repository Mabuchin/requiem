defmodule Requiem.Transport.RustUDP do
  use GenServer
  require Logger
  require Requiem.Tracer

  alias Requiem.Address
  alias Requiem.QUIC
  alias Requiem.Tracer

  @type t :: %__MODULE__{
          handler: module,
          dispatcher: module,
          port: non_neg_integer,
          event_capacity: non_neg_integer,
          polling_timeout: non_neg_integer,
          sock: port
        }

  defstruct handler: nil,
            dispatcher: nil,
            port: 0,
            event_capacity: 0,
            polling_timeout: 0,
            sock: nil

  def batch_send(handler, batch) do
    handler |> name() |> GenServer.cast({:batch_send, batch})
  end

  def send(handler, address, packet) do
    handler |> name() |> GenServer.cast({:send, address, packet})
  end

  def start_link(opts) do
    name = Keyword.fetch!(opts, :handler) |> name()
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    state = new(opts)

    case QUIC.Socket.open(
           "0.0.0.0",
           state.port,
           self(),
           state.event_capacity,
           state.polling_timeout
         ) do
      {:ok, sock} ->
        Logger.info("<Requiem.Transport.RustUDP> opened")
        Process.flag(:trap_exit, true)
        {:ok, %{state | sock: sock}}

      {:error, reason} ->
        Logger.error(
          "<Requiem.Transport.RustUDP> failed to open UDP port #{to_string(state.port)}: #{
            inspect(reason)
          }"
        )

        {:stop, :normal}
    end
  end

  @impl GenServer
  def handle_cast({:send, address, packet}, state) do
    Tracer.trace(__MODULE__, "@send")
    send_packet(state.sock, address, packet)
    {:noreply, state}
  end

  def handle_cast({:batch_send, batch}, state) do
    Tracer.trace(__MODULE__, "@batch_send")

    batch
    |> Enum.each(fn {address, packet} ->
      send_packet(state.sock, address, packet)
    end)

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:__packet__, peer, data}, state) do
    Tracer.trace(__MODULE__, "@received")
    {:ok, host, port} = QUIC.Socket.address_parts(peer)

    address =
      if byte_size(host) == 4 do
        <<n1, n2, n3, n4>> = host
        Address.new({n1, n2, n3, n4}, port, peer)
      else
        <<
          n1::unsigned-integer-size(16),
          n2::unsigned-integer-size(16),
          n3::unsigned-integer-size(16),
          n4::unsigned-integer-size(16),
          n5::unsigned-integer-size(16),
          n6::unsigned-integer-size(16),
          n7::unsigned-integer-size(16),
          n8::unsigned-integer-size(16)
        >> = host

        Address.new({n1, n2, n3, n4, n5, n6, n7, n8}, port, peer)
      end

    state.dispatcher.dispatch(state.handler, address, data)
    {:noreply, state}
  end

  def handle_info({:socket_error, reason}, state) do
    Tracer.trace(__MODULE__, "@rust_error: #{inspect(reason)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, _state) do
    Logger.info("<Requiem.Transport.RustUDP> @terminate: #{inspect(reason)}")
    :ok
  end

  defp new(opts) do
    %__MODULE__{
      handler: Keyword.fetch!(opts, :handler),
      dispatcher: Keyword.fetch!(opts, :dispatcher),
      port: Keyword.fetch!(opts, :port),
      event_capacity: Keyword.get(opts, :event_capacity, 1024),
      polling_timeout: Keyword.get(opts, :polling_timeout, 10),
      sock: nil
    }
  end

  defp send_packet(sock, address, packet) do
    Tracer.trace(__MODULE__, "send packet")

    QUIC.Socket.send(
      sock,
      address.raw,
      packet
    )
  end

  defp name(handler),
    do: Module.concat(handler, __MODULE__)
end
