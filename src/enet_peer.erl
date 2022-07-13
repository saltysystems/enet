-module(enet_peer).
-behaviour(gen_statem).

-include("enet_peer.hrl").
-include("enet_commands.hrl").
-include("enet_protocol.hrl").

%% API
-export([
    start_link/2,
    disconnect/1,
    disconnect_now/1,
    channels/1,
    channel/2,
    recv_incoming_packet/4,
    send_command/2,
    get_connect_id/1,
    get_mtu/1,
    get_name/1,
    get_peer_id/1,
    get_pool/1,
    get_pool_worker_id/1
]).

%% gen_statem callbacks
-export([
    init/1,
    callback_mode/0,
    terminate/3,
    code_change/4
]).

%% gen_statem state functions
-export([
    connecting/3,
    acknowledging_connect/3,
    acknowledging_verify_connect/3,
    verifying_connect/3,
    connected/3,
    disconnecting/3
]).

-record(state, {
    local_port,
    ip,
    port,
    remote_peer_id = undefined,
    peer_id,
    incoming_session_id = 16#FF,
    outgoing_session_id = 16#FF,
    incoming_bandwidth = 0,
    outgoing_bandwidth = 0,
    window_size = ?MAX_WINDOW_SIZE,
    packet_throttle_interval = ?PEER_PACKET_THROTTLE_INTERVAL,
    packet_throttle_acceleration = ?PEER_PACKET_THROTTLE_ACCELERATION,
    packet_throttle_deceleration = ?PEER_PACKET_THROTTLE_DECELERATION,
    outgoing_reliable_sequence_number = 1,
    incoming_unsequenced_group = 0,
    outgoing_unsequenced_group = 1,
    unsequenced_window = 0,
    connect_id,
    host,
    channel_count,
    channels,
    worker,
    connect_fun
}).

%%==============================================================
%% Connection handshake
%%==============================================================
%%
%%
%%      state    client              server     state
%%          (init) *
%%                 |       connect
%%                 |------------------->* (init)
%%    'connecting' |                    | 'acknowledging connect'
%%                 |     ack connect    |
%%                 |<-------------------|
%%  'acknowledging |                    |
%% verify connect' |                    |
%%                 |   verify connect   |
%%                 |<-------------------|
%%                 |                    | 'verifying connect'
%%                 | ack verify connect |
%%                 |------------------->|
%%     'connected' |                    | 'connected'
%%                 |                    |
%%
%%
%%==============================================================

%%==============================================================
%% Disconnect procedure
%%==============================================================
%%
%%
%%      state   client               server   state
%%               peer                 peer
%%                 |                    |
%%     'connected' |                    | 'connected'
%%                 |     disconnect     |
%%                 |------------------->|
%% 'disconnecting' |                    |
%%                 |   ack disconnect   |
%%                 |<-------------------|
%%          (exit) |                    | (exit)
%%                 *                    *
%%
%%
%%==============================================================

%%%===================================================================
%%% API
%%%===================================================================

start_link(LocalPort, Peer) ->
    gen_statem:start_link(?MODULE, [LocalPort, Peer], []).

disconnect(Peer) ->
    gen_statem:cast(Peer, disconnect).

disconnect_now(Peer) ->
    gen_statem:cast(Peer, disconnect_now).

channels(Peer) ->
    gen_statem:call(Peer, channels).

channel(Peer, ID) ->
    gen_statem:call(Peer, {channel, ID}).

recv_incoming_packet(Peer, FromIP, SentTime, Packet) ->
    gen_statem:cast(Peer, {incoming_packet, FromIP, SentTime, Packet}).

send_command(Peer, {H, C}) ->
    gen_statem:cast(Peer, {outgoing_command, {H, C}}).

get_connect_id(Peer) ->
    gproc:get_value({p, l, connect_id}, Peer).

get_mtu(Peer) ->
    gproc:get_value({p, l, mtu}, Peer).

get_name(Peer) ->
    gproc:get_value({p, l, name}, Peer).

get_peer_id(Peer) ->
    gproc:get_value({p, l, peer_id}, Peer).

get_pool(Peer) ->
    gen_statem:call(Peer, pool).

get_pool_worker_id(Peer) ->
    gen_statem:call(Peer, pool_worker_id).

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

init([LocalPort, P = #enet_peer{handshake_flow = local}]) ->
    %%
    %% The client application wants to connect to a remote peer.
    %%
    %% - Send a Connect command to the remote peer (use peer ID)
    %% - Start in the 'connecting' state
    %%
    #enet_peer{
        peer_id = PeerID,
        ip = IP,
        port = Port,
        name = Ref,
        host = Host,
        channels = N,
        connect_fun = ConnectFun
    } = P,
    enet_pool:connect_peer(LocalPort, Ref),
    gproc:reg({n, l, {enet_peer, Ref}}),
    gproc:reg({p, l, name}, Ref),
    gproc:reg({p, l, peer_id}, PeerID),
    S = #state{
        host = Host,
        local_port = LocalPort,
        ip = IP,
        port = Port,
        peer_id = PeerID,
        channel_count = N,
        connect_fun = ConnectFun
    },
    {ok, connecting, S};
init([LocalPort, P = #enet_peer{handshake_flow = remote}]) ->
    %%
    %% A remote peer wants to connect to the client application.
    %%
    %% - Start in the 'acknowledging_connect' state
    %% - Handle the received Connect command
    %%
    #enet_peer{
        peer_id = PeerID,
        ip = IP,
        port = Port,
        name = Ref,
        host = Host,
        connect_fun = ConnectFun
    } = P,
    enet_pool:connect_peer(LocalPort, Ref),
    gproc:reg({n, l, {enet_peer, Ref}}),
    gproc:reg({p, l, name}, Ref),
    gproc:reg({p, l, peer_id}, PeerID),
    S = #state{
        host = Host,
        local_port = LocalPort,
        ip = IP,
        port = Port,
        peer_id = PeerID,
        connect_fun = ConnectFun
    },
    {ok, acknowledging_connect, S}.

callback_mode() ->
    [state_functions, state_enter].

%%%
%%% Connecting state
%%%

connecting(enter, _OldState, S) ->
    %%
    %% Sending the initial Connect command.
    %%
    #state{
        host = Host,
        channel_count = ChannelCount,
        ip = IP,
        port = Port,
        peer_id = PeerID,
        incoming_session_id = IncomingSessionID,
        outgoing_session_id = OutgoingSessionID,
        packet_throttle_interval = PacketThrottleInterval,
        packet_throttle_acceleration = PacketThrottleAcceleration,
        packet_throttle_deceleration = PacketThrottleDeceleration,
        outgoing_reliable_sequence_number = SequenceNr
    } = S,
    IncomingBandwidth = enet_host:get_incoming_bandwidth(Host),
    OutgoingBandwidth = enet_host:get_outgoing_bandwidth(Host),
    MTU = enet_host:get_mtu(Host),
    gproc:reg({p, l, mtu}, MTU),
    <<ConnectID:32>> = crypto:strong_rand_bytes(4),
    {ConnectH, ConnectC} =
        enet_command:connect(
            PeerID,
            IncomingSessionID,
            OutgoingSessionID,
            ChannelCount,
            MTU,
            IncomingBandwidth,
            OutgoingBandwidth,
            PacketThrottleInterval,
            PacketThrottleAcceleration,
            PacketThrottleDeceleration,
            ConnectID,
            SequenceNr
        ),
    HBin = enet_protocol_encode:command_header(ConnectH),
    CBin = enet_protocol_encode:command(ConnectC),
    Data = [HBin, CBin],
    {sent_time, SentTime} =
        enet_host:send_outgoing_commands(Host, Data, IP, Port),
    ChannelID = 16#FF,
    ConnectTimeout =
        make_resend_timer(
            ChannelID, SentTime, SequenceNr, ?PEER_TIMEOUT_MINIMUM, Data
        ),
    NewS = S#state{
        outgoing_reliable_sequence_number = SequenceNr + 1,
        connect_id = ConnectID
    },
    {keep_state, NewS, [ConnectTimeout]};
connecting(cast, {incoming_command, {H, C = #acknowledge{}}}, S) ->
    %%
    %% Received an Acknowledge command in the 'connecting' state.
    %%
    %% - Verify that the acknowledge is correct
    %% - Change state to 'acknowledging_verify_connect'
    %%
    #command_header{channel_id = ChannelID} = H,
    #acknowledge{
        received_reliable_sequence_number = SequenceNumber,
        received_sent_time = SentTime
    } = C,
    CanceledTimeout = cancel_resend_timer(ChannelID, SentTime, SequenceNumber),
    {next_state, acknowledging_verify_connect, S, [CanceledTimeout]};
connecting({timeout, {_ChannelID, _SentTime, _SequenceNumber}}, _, S) ->
    {stop, timeout, S};
connecting(EventType, EventContent, S) ->
    handle_event(EventType, EventContent, S).

%%%
%%% Acknowledging Connect state
%%%

acknowledging_connect(enter, _OldState, S) ->
    {keep_state, S};
acknowledging_connect(cast, {incoming_command, {_H, C = #connect{}}}, S) ->
    %%
    %% Received a Connect command.
    %%
    %% - Verify that the data is sane (TODO)
    %% - Send a VerifyConnect command (use peer ID)
    %% - Start in the 'verifying_connect' state
    %%
    #connect{
        outgoing_peer_id = RemotePeerID,
        incoming_session_id = _IncomingSessionID,
        outgoing_session_id = _OutgoingSessionID,
        mtu = MTU,
        window_size = WindowSize,
        channel_count = ChannelCount,
        incoming_bandwidth = IncomingBandwidth,
        outgoing_bandwidth = OutgoingBandwidth,
        packet_throttle_interval = PacketThrottleInterval,
        packet_throttle_acceleration = PacketThrottleAcceleration,
        packet_throttle_deceleration = PacketThrottleDeceleration,
        connect_id = ConnectID,
        data = _Data
    } = C,
    #state{
        host = Host,
        ip = IP,
        port = Port,
        peer_id = PeerID,
        incoming_session_id = IncomingSessionID,
        outgoing_session_id = OutgoingSessionID,
        outgoing_reliable_sequence_number = SequenceNr
    } = S,
    gproc:reg({p, l, mtu}, MTU),
    HostChannelLimit = enet_host:get_channel_limit(Host),
    HostIncomingBandwidth = enet_host:get_incoming_bandwidth(Host),
    HostOutgoingBandwidth = enet_host:get_outgoing_bandwidth(Host),
    {VCH, VCC} = enet_command:verify_connect(
        C,
        PeerID,
        IncomingSessionID,
        OutgoingSessionID,
        HostChannelLimit,
        HostIncomingBandwidth,
        HostOutgoingBandwidth,
        SequenceNr
    ),
    HBin = enet_protocol_encode:command_header(VCH),
    CBin = enet_protocol_encode:command(VCC),
    Data = [HBin, CBin],
    {sent_time, SentTime} =
        enet_host:send_outgoing_commands(Host, Data, IP, Port, RemotePeerID),
    ChannelID = 16#FF,
    VerifyConnectTimeout =
        make_resend_timer(
            ChannelID, SentTime, SequenceNr, ?PEER_TIMEOUT_MINIMUM, Data
        ),
    NewS = S#state{
        remote_peer_id = RemotePeerID,
        %% channels = Channels,
        connect_id = ConnectID,
        incoming_bandwidth = IncomingBandwidth,
        outgoing_bandwidth = OutgoingBandwidth,
        window_size = WindowSize,
        packet_throttle_interval = PacketThrottleInterval,
        packet_throttle_acceleration = PacketThrottleAcceleration,
        packet_throttle_deceleration = PacketThrottleDeceleration,
        outgoing_reliable_sequence_number = SequenceNr + 1,
        channel_count = ChannelCount
    },
    {next_state, verifying_connect, NewS, [VerifyConnectTimeout]};
acknowledging_connect({timeout, {_ChannelID, _SentTime, _SequenceNr}}, _, S) ->
    {stop, timeout, S};
acknowledging_connect(EventType, EventContent, S) ->
    handle_event(EventType, EventContent, S).

%%%
%%% Acknowledging Verify Connect state
%%%

acknowledging_verify_connect(enter, _OldState, S) ->
    {keep_state, S};
acknowledging_verify_connect(
    cast, {incoming_command, {_H, C = #verify_connect{}}}, S
) ->
    %%
    %% Received a Verify Connect command in the 'acknowledging_verify_connect'
    %% state.
    %%
    %% - Verify that the data is correct
    %% - Add the remote peer ID to the Peer Table
    %% - Notify worker that we are connected
    %% - Change state to 'connected'
    %%
    #verify_connect{
        outgoing_peer_id = RemotePeerID,
        incoming_session_id = _IncomingSessionID,
        outgoing_session_id = _OutgoingSessionID,
        mtu = RemoteMTU,
        window_size = WindowSize,
        channel_count = RemoteChannelCount,
        incoming_bandwidth = IncomingBandwidth,
        outgoing_bandwidth = OutgoingBandwidth,
        packet_throttle_interval = ThrottleInterval,
        packet_throttle_acceleration = ThrottleAcceleration,
        packet_throttle_deceleration = ThrottleDeceleration,
        connect_id = ConnectID
    } = C,
    %%
    %% TODO: Calculate and validate Session IDs
    %%
    #state{channel_count = LocalChannelCount} = S,
    LocalMTU = get_mtu(self()),
    case S of
        #state{
            %% ---
            %% Fields below are matched against the values received in
            %% the Verify Connect command.
            %% ---
            window_size = WindowSize,
            incoming_bandwidth = IncomingBandwidth,
            outgoing_bandwidth = OutgoingBandwidth,
            packet_throttle_interval = ThrottleInterval,
            packet_throttle_acceleration = ThrottleAcceleration,
            packet_throttle_deceleration = ThrottleDeceleration,
            connect_id = ConnectID
            %% ---
        } when
            LocalChannelCount =:= RemoteChannelCount,
            LocalMTU =:= RemoteMTU
        ->
            NewS = S#state{remote_peer_id = RemotePeerID},
            {next_state, connected, NewS};
        _Mismatch ->
            {stop, connect_verification_failed, S}
    end;
acknowledging_verify_connect(EventType, EventContent, S) ->
    handle_event(EventType, EventContent, S).

%%%
%%% Verifying Connect state
%%%

verifying_connect(enter, _OldState, S) ->
    {keep_state, S};
verifying_connect(cast, {incoming_command, {H, C = #acknowledge{}}}, S) ->
    %%
    %% Received an Acknowledge command in the 'verifying_connect' state.
    %%
    %% - Verify that the acknowledge is correct
    %% - Notify worker that a new peer has been connected
    %% - Change to 'connected' state
    %%
    #command_header{channel_id = ChannelID} = H,
    #acknowledge{
        received_reliable_sequence_number = SequenceNumber,
        received_sent_time = SentTime
    } = C,
    CanceledTimeout = cancel_resend_timer(ChannelID, SentTime, SequenceNumber),
    {next_state, connected, S, [CanceledTimeout]};
verifying_connect(EventType, EventContent, S) ->
    handle_event(EventType, EventContent, S).

%%%
%%% Connected state
%%%

connected(enter, _OldState, S) ->
    #state{
        local_port = LocalPort,
        ip = IP,
        port = Port,
        remote_peer_id = RemotePeerID,
        connect_id = ConnectID,
        channel_count = N,
        connect_fun = ConnectFun
    } = S,
    true = gproc:mreg(p, l, [
        {connect_id, ConnectID},
        {remote_host_port, Port},
        {remote_peer_id, RemotePeerID}
    ]),
    ok = enet_disconnector:set_trigger(LocalPort, RemotePeerID, IP, Port),
    Channels = start_channels(N),
    PeerInfo = #{
        ip => IP,
        port => Port,
        peer => self(),
        channels => Channels,
        connect_id => ConnectID
    },
    case start_worker(ConnectFun, PeerInfo) of
        {error, Reason} ->
            {stop, {worker_init_error, Reason}, S};
        {ok, Worker} ->
            _Ref = monitor(process, Worker),
            [
                enet_channel_srv:set_worker(C, Worker)
             || C <- maps:values(Channels)
            ],
            NewS = S#state{
                channels = Channels,
                worker = Worker
            },
            SendTimeout = reset_send_timer(),
            RecvTimeout = reset_recv_timer(),
            {keep_state, NewS, [SendTimeout, RecvTimeout]}
    end;
connected(cast, {incoming_command, {_H, #ping{}}}, S) ->
    %%
    %% Received PING.
    %%
    %% - Reset the receive-timer
    %%
    RecvTimeout = reset_recv_timer(),
    {keep_state, S, [RecvTimeout]};
connected(cast, {incoming_command, {H, C = #acknowledge{}}}, S) ->
    %%
    %% Received an Acknowledge command.
    %%
    %% - Verify that the acknowledge is correct
    %% - Reset the receive-timer
    %%
    #command_header{channel_id = ChannelID} = H,
    #acknowledge{
        received_reliable_sequence_number = SequenceNumber,
        received_sent_time = SentTime
    } = C,
    CanceledTimeout = cancel_resend_timer(ChannelID, SentTime, SequenceNumber),
    RecvTimeout = reset_recv_timer(),
    {keep_state, S, [CanceledTimeout, RecvTimeout]};
connected(cast, {incoming_command, {_H, C = #bandwidth_limit{}}}, S) ->
    %%
    %% Received Bandwidth Limit command.
    %%
    %% - Set bandwidth limit
    %% - Reset the receive-timer
    %%
    #bandwidth_limit{
        incoming_bandwidth = IncomingBandwidth,
        outgoing_bandwidth = OutgoingBandwidth
    } = C,
    #state{host = Host} = S,
    HostOutgoingBandwidth = enet_host:get_outgoing_bandwidth(Host),
    WSize =
        case {IncomingBandwidth, HostOutgoingBandwidth} of
            {0, 0} -> ?MAX_WINDOW_SIZE;
            {0, H} -> ?MIN_WINDOW_SIZE * H div ?PEER_WINDOW_SIZE_SCALE;
            {P, 0} -> ?MIN_WINDOW_SIZE * P div ?PEER_WINDOW_SIZE_SCALE;
            {P, H} -> ?MIN_WINDOW_SIZE * min(P, H) div ?PEER_WINDOW_SIZE_SCALE
        end,
    NewS = S#state{
        incoming_bandwidth = IncomingBandwidth,
        outgoing_bandwidth = OutgoingBandwidth,
        window_size = max(?MIN_WINDOW_SIZE, min(?MAX_WINDOW_SIZE, WSize))
    },
    RecvTimeout = reset_recv_timer(),
    {keep_state, NewS, [RecvTimeout]};
connected(cast, {incoming_command, {_H, C = #throttle_configure{}}}, S) ->
    %%
    %% Received Throttle Configure command.
    %%
    %% - Set throttle configuration
    %% - Reset the receive-timer
    %%
    #throttle_configure{
        packet_throttle_interval = Interval,
        packet_throttle_acceleration = Acceleration,
        packet_throttle_deceleration = Deceleration
    } = C,
    NewS = S#state{
        packet_throttle_interval = Interval,
        packet_throttle_acceleration = Acceleration,
        packet_throttle_deceleration = Deceleration
    },
    RecvTimeout = reset_recv_timer(),
    {keep_state, NewS, [RecvTimeout]};
connected(cast, {incoming_command, {H, C = #unsequenced{}}}, S) ->
    %%
    %% Received Send Unsequenced command.
    %%
    %% - Forward the command to the relevant channel
    %% - Reset the receive-timer
    %%
    #command_header{channel_id = ChannelID} = H,
    #state{channels = #{ChannelID := Channel}} = S,
    ok = enet_channel_srv:recv_unsequenced(Channel, {H, C}),
    RecvTimeout = reset_recv_timer(),
    {keep_state, S, [RecvTimeout]};
connected(cast, {incoming_command, {H, C = #unreliable{}}}, S) ->
    %%
    %% Received Send Unreliable command.
    %%
    %% - Forward the command to the relevant channel
    %% - Reset the receive-timer
    %%
    #command_header{channel_id = ChannelID} = H,
    #state{channels = #{ChannelID := Channel}} = S,
    ok = enet_channel_srv:recv_unreliable(Channel, {H, C}),
    RecvTimeout = reset_recv_timer(),
    {keep_state, S, [RecvTimeout]};
connected(cast, {incoming_command, {H, C = #reliable{}}}, S) ->
    %%
    %% Received Send Reliable command.
    %%
    %% - Forward the command to the relevant channel
    %% - Reset the receive-timer
    %%
    #command_header{channel_id = ChannelID} = H,
    #state{channels = #{ChannelID := Channel}} = S,
    ok = enet_channel_srv:recv_reliable(Channel, {H, C}),
    RecvTimeout = reset_recv_timer(),
    {keep_state, S, [RecvTimeout]};
connected(cast, {incoming_command, {_H, #disconnect{}}}, S) ->
    %%
    %% Received Disconnect command.
    %%
    %% - Notify worker application
    %% - Stop
    %%
    #state{
        worker = Worker,
        local_port = LocalPort,
        ip = IP,
        port = Port,
        remote_peer_id = RemotePeerID,
        connect_id = ConnectID
    } = S,
    ok = enet_disconnector:unset_trigger(LocalPort, RemotePeerID, IP, Port),
    Worker ! {enet, disconnected, remote, self(), ConnectID},
    {stop, normal, S};
connected(cast, {outgoing_command, {H, C = #unsequenced{}}}, S) ->
    %%
    %% Sending an Unsequenced, unreliable command.
    %%
    %% - TODO: Increment total data passed through peer
    %% - Increment outgoing_unsequenced_group
    %% - Set unsequenced_group on command to outgoing_unsequenced_group
    %% - Queue the command for sending
    %% - Reset the send-timer
    %%
    #state{
        host = Host,
        ip = IP,
        port = Port,
        remote_peer_id = RemotePeerID,
        outgoing_unsequenced_group = Group
    } = S,
    C1 = C#unsequenced{group = Group},
    HBin = enet_protocol_encode:command_header(H),
    CBin = enet_protocol_encode:command(C1),
    Data = [HBin, CBin],
    {sent_time, _SentTime} =
        enet_host:send_outgoing_commands(Host, Data, IP, Port, RemotePeerID),
    NewS = S#state{outgoing_unsequenced_group = Group + 1},
    SendTimeout = reset_send_timer(),
    {keep_state, NewS, [SendTimeout]};
connected(cast, {outgoing_command, {H, C = #unreliable{}}}, S) ->
    %%
    %% Sending a Sequenced, unreliable command.
    %%
    %% - Forward the encoded command to the host
    %% - Reset the send-timer
    %%
    #state{
        host = Host,
        ip = IP,
        port = Port,
        remote_peer_id = RemotePeerID
    } = S,
    HBin = enet_protocol_encode:command_header(H),
    CBin = enet_protocol_encode:command(C),
    Data = [HBin, CBin],
    {sent_time, _SentTime} =
        enet_host:send_outgoing_commands(Host, Data, IP, Port, RemotePeerID),
    SendTimeout = reset_send_timer(),
    {keep_state, S, [SendTimeout]};
connected(cast, {outgoing_command, {H, C = #reliable{}}}, S) ->
    %%
    %% Sending a Sequenced, reliable command.
    %%
    %% - Forward the encoded command to the host
    %% - Reset the send-timer
    %%
    #state{
        host = Host,
        ip = IP,
        port = Port,
        remote_peer_id = RemotePeerID
    } = S,
    #command_header{
        channel_id = ChannelID,
        reliable_sequence_number = SequenceNr
    } = H,
    HBin = enet_protocol_encode:command_header(H),
    CBin = enet_protocol_encode:command(C),
    Data = [HBin, CBin],
    {sent_time, SentTime} =
        enet_host:send_outgoing_commands(Host, Data, IP, Port, RemotePeerID),
    SendReliableTimeout =
        make_resend_timer(
            ChannelID, SentTime, SequenceNr, ?PEER_TIMEOUT_MINIMUM, Data
        ),
    SendTimeout = reset_send_timer(),
    {keep_state, S, [SendReliableTimeout, SendTimeout]};
connected(cast, disconnect, State) ->
    %%
    %% Disconnecting.
    %%
    %% - Queue a Disconnect command for sending
    %% - Change state to 'disconnecting'
    %%
    #state{
        host = Host,
        ip = IP,
        port = Port,
        remote_peer_id = RemotePeerID
    } = State,
    {H, C} = enet_command:sequenced_disconnect(),
    HBin = enet_protocol_encode:command_header(H),
    CBin = enet_protocol_encode:command(C),
    Data = [HBin, CBin],
    enet_host:send_outgoing_commands(Host, Data, IP, Port, RemotePeerID),
    {next_state, disconnecting, State};
connected(cast, disconnect_now, State) ->
    %%
    %% Disconnecting immediately.
    %%
    %% - Stop
    %%
    {stop, normal, State};
connected({timeout, {ChannelID, SentTime, SequenceNr}}, Data, S) ->
    %%
    %% A resend-timer was triggered.
    %%
    %% - TODO: Keep track of number of resends
    %% - Resend the associated command
    %% - Reset the resend-timer
    %% - Reset the send-timer
    %%
    #state{
        host = Host,
        ip = IP,
        port = Port,
        remote_peer_id = RemotePeerID
    } = S,
    enet_host:send_outgoing_commands(Host, Data, IP, Port, RemotePeerID),
    NewTimeout =
        make_resend_timer(
            ChannelID, SentTime, SequenceNr, ?PEER_TIMEOUT_MINIMUM, Data
        ),
    SendTimeout = reset_send_timer(),
    {keep_state, S, [NewTimeout, SendTimeout]};
connected({timeout, recv}, ping, S) ->
    %%
    %% The receive-timer was triggered.
    %%
    %% - Stop
    %%
    {stop, timeout, S};
connected({timeout, send}, ping, S) ->
    %%
    %% The send-timer was triggered.
    %%
    %% - Send a PING
    %% - Reset the send-timer
    %%
    #state{
        host = Host,
        ip = IP,
        port = Port,
        remote_peer_id = RemotePeerID
    } = S,
    {H, C} = enet_command:ping(),
    HBin = enet_protocol_encode:command_header(H),
    CBin = enet_protocol_encode:command(C),
    Data = [HBin, CBin],
    {sent_time, _SentTime} =
        enet_host:send_outgoing_commands(Host, Data, IP, Port, RemotePeerID),
    SendTimeout = reset_send_timer(),
    {keep_state, S, [SendTimeout]};
connected(EventType, EventContent, S) ->
    handle_event(EventType, EventContent, S).

%%%
%%% Disconnecting state
%%%

disconnecting(enter, _OldState, S) ->
    #state{
        local_port = LocalPort,
        ip = IP,
        port = Port,
        remote_peer_id = RemotePeerID
    } = S,
    ok = enet_disconnector:unset_trigger(LocalPort, RemotePeerID, IP, Port),
    {keep_state, S};
disconnecting(cast, {incoming_command, {_H, _C = #acknowledge{}}}, S) ->
    %%
    %% Received an Acknowledge command in the 'disconnecting' state.
    %%
    %% - Verify that the acknowledge is correct
    %% - Notify worker application
    %% - Stop
    %%
    #state{
        worker = Worker,
        connect_id = ConnectID
    } = S,
    Worker ! {enet, disconnected, local, self(), ConnectID},
    {stop, normal, S};
disconnecting(cast, {incoming_command, {_H, _C}}, S) ->
    {keep_state, S};
disconnecting(EventType, EventContent, S) ->
    handle_event(EventType, EventContent, S).

%%%
%%% terminate
%%%

terminate(_Reason, _StateName, #state{local_port = LocalPort}) ->
    Name = get_name(self()),
    enet_pool:disconnect_peer(LocalPort, Name),
    ok.

%%%
%%% code_change
%%%

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

handle_event(cast, {incoming_packet, FromIP, SentTime, Packet}, S) ->
    %%
    %% Received an incoming packet of commands.
    %%
    %% - Split and decode the commands from the binary
    %% - Send the commands as individual events to ourselves
    %%
    #state{host = Host, port = Port} = S,
    {ok, Commands} = enet_protocol_decode:commands(Packet),
    lists:foreach(
        fun
            ({H = #command_header{please_acknowledge = 0}, C}) ->
                %%
                %% Received command that does not need to be acknowledged.
                %%
                %% - Send the command to self for handling
                %%
                gen_statem:cast(self(), {incoming_command, {H, C}});
            ({H = #command_header{please_acknowledge = 1}, C}) ->
                %%
                %% Received a command that should be acknowledged.
                %%
                %% - Acknowledge the command
                %% - Send the command to self for handling
                %%
                {AckH, AckC} = enet_command:acknowledge(H, SentTime),
                HBin = enet_protocol_encode:command_header(AckH),
                CBin = enet_protocol_encode:command(AckC),
                RemotePeerID =
                    case C of
                        #connect{} -> C#connect.outgoing_peer_id;
                        #verify_connect{} -> C#verify_connect.outgoing_peer_id;
                        _ -> S#state.remote_peer_id
                    end,
                {sent_time, _AckSentTime} =
                    enet_host:send_outgoing_commands(
                        Host, [HBin, CBin], FromIP, Port, RemotePeerID
                    ),
                gen_statem:cast(self(), {incoming_command, {H, C}})
        end,
        Commands
    ),
    {keep_state, S#state{ip = FromIP}};
handle_event({call, From}, channels, S) ->
    {keep_state, S, [{reply, From, S#state.channels}]};
handle_event({call, From}, pool, S) ->
    {keep_state, S, [{reply, From, S#state.local_port}]};
handle_event({call, From}, pool_worker_id, S) ->
    WorkerID = enet_pool:worker_id(S#state.local_port, get_name(self())),
    {keep_state, S, [{reply, From, WorkerID}]};
handle_event({call, From}, {channel, ID}, S) ->
    #state{channels = #{ID := Channel}} = S,
    {keep_state, S, [{reply, From, Channel}]};
handle_event(info, {'DOWN', _, process, O, _}, S = #state{worker = O}) ->
    {stop, worker_process_down, S}.

start_channels(N) ->
    IDs = lists:seq(0, N - 1),
    Channels =
        lists:map(
            fun(ID) ->
                {ok, Channel} = enet_channel_srv:start_link(ID, self()),
                {ID, Channel}
            end,
            IDs
        ),
    maps:from_list(Channels).

make_resend_timer(ChannelID, SentTime, SequenceNumber, Time, Data) ->
    {{timeout, {ChannelID, SentTime, SequenceNumber}}, Time, Data}.

cancel_resend_timer(ChannelID, SentTime, SequenceNumber) ->
    {{timeout, {ChannelID, SentTime, SequenceNumber}}, infinity, undefined}.

reset_recv_timer() ->
    {{timeout, recv}, 2 * ?PEER_PING_INTERVAL, ping}.

reset_send_timer() ->
    {{timeout, send}, ?PEER_PING_INTERVAL, ping}.

start_worker({Module, Fun, Args}, PeerInfo) ->
    erlang:apply(Module, Fun, Args ++ [PeerInfo]);
start_worker(ConnectFun, PeerInfo) ->
    ConnectFun(PeerInfo).
