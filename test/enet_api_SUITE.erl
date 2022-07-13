-module(enet_api_SUITE).
-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("enet/include/enet.hrl").

suite() ->
    [{timetrap, {seconds, 30}}].

init_per_suite(Config) ->
    application:ensure_all_started(enet),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(_GroupName, Config) ->
    Config.

end_per_group(_GroupName, _Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

groups() ->
    [].

all() ->
    [
        local_worker_init_error_test,
        local_zero_peer_limit_test,
        remote_zero_peer_limit_test,
        broadcast_connect_test,
        local_disconnect_test,
        remote_disconnect_test,
        unsequenced_messages_test,
        unreliable_messages_test,
        reliable_messages_test,
        unsequenced_broadcast_test,
        unreliable_broadcast_test,
        reliable_broadcast_test
    ].

local_worker_init_error_test(_Config) ->
    ConnectFun = fun(_PeerInfo) -> {error, whatever} end,
    {ok, LocalHost} = enet:start_host(0, ConnectFun, [{peer_limit, 1}]),
    {ok, RemoteHost} = enet:start_host(0, ConnectFun, [{peer_limit, 1}]),
    {ok, LocalPeer} = enet:connect_peer(LocalHost, "127.0.0.1", RemoteHost, 1),
    Ref = monitor(process, LocalPeer),
    receive
        {'DOWN', Ref, process, LocalPeer, {worker_init_error, whatever}} -> ok
    after 1000 ->
        exit(local_peer_did_not_stop_on_worker_init_error)
    end,
    ok = enet:stop_host(LocalHost),
    ok = enet:stop_host(RemoteHost).

local_zero_peer_limit_test(_Config) ->
    Self = self(),
    ConnectFun = fun(_PeerInfo) -> {ok, Self} end,
    {ok, LocalHost} = enet:start_host(0, ConnectFun, [{peer_limit, 0}]),
    {ok, RemoteHost} = enet:start_host(0, ConnectFun, [{peer_limit, 1}]),
    {error, reached_peer_limit} =
        enet:connect_peer(LocalHost, "127.0.0.1", RemoteHost, 1),
    ok = enet:stop_host(LocalHost),
    ok = enet:stop_host(RemoteHost).

remote_zero_peer_limit_test(_Config) ->
    Self = self(),
    ConnectFun = fun(PeerInfo) ->
        Self ! PeerInfo,
        {ok, Self}
    end,
    {ok, LocalHost} = enet:start_host(0, ConnectFun, [{peer_limit, 1}]),
    {ok, RemoteHost} = enet:start_host(0, ConnectFun, [{peer_limit, 0}]),
    {ok, Peer} = enet:connect_peer(LocalHost, "127.0.0.1", RemoteHost, 1),
    receive
        #{peer := Peer} ->
            exit(peer_could_connect_despite_peer_limit_reached)
        %% How long time is enough? (This is ugly)
    after 200 ->
        ok
    end,
    ok = enet:stop_host(LocalHost),
    ok = enet:stop_host(RemoteHost).

broadcast_connect_test(_Config) ->
    Self = self(),
    ConnectFun = fun(PeerInfo) ->
        Self ! PeerInfo,
        {ok, Self}
    end,
    {ok, LocalHost} = enet:start_host(0, ConnectFun, [{peer_limit, 1}]),
    {ok, RemoteHost} = enet:start_host(0, ConnectFun, [{peer_limit, 1}]),
    {ok, LocalPeer} =
        enet:connect_peer(LocalHost, "255.255.255.255", RemoteHost, 1),
    ConnectID =
        receive
            #{peer := LocalPeer, connect_id := C} -> C
        after 1000 ->
            exit(local_peer_did_not_notify_worker)
        end,
    RemotePeer =
        receive
            #{peer := P, connect_id := ConnectID} -> P
        after 1000 ->
            exit(remote_peer_did_not_notify_worker)
        end,
    Ref1 = monitor(process, LocalPeer),
    Ref2 = monitor(process, RemotePeer),
    ok = enet:disconnect_peer(LocalPeer),
    receive
        {enet, disconnected, local, LocalPeer, ConnectID} -> ok
    after 1000 ->
        exit(local_peer_did_not_notify_worker)
    end,
    receive
        {enet, disconnected, remote, RemotePeer, ConnectID} -> ok
    after 1000 ->
        exit(remote_peer_did_not_notify_worker)
    end,
    receive
        {'DOWN', Ref1, process, LocalPeer, normal} -> ok
    after 1000 ->
        exit(local_peer_did_not_exit)
    end,
    receive
        {'DOWN', Ref2, process, RemotePeer, normal} -> ok
    after 1000 ->
        exit(remote_peer_did_not_exit)
    end,
    ok = enet:stop_host(LocalHost),
    ok = enet:stop_host(RemoteHost).

local_disconnect_test(_Config) ->
    Self = self(),
    ConnectFun = fun(PeerInfo) ->
        Self ! PeerInfo,
        {ok, Self}
    end,
    {ok, LocalHost} = enet:start_host(0, ConnectFun, [{peer_limit, 8}]),
    {ok, RemoteHost} = enet:start_host(0, ConnectFun, [{peer_limit, 8}]),
    {ok, LocalPeer} = enet:connect_peer(LocalHost, "127.0.0.1", RemoteHost, 1),
    ConnectID =
        receive
            #{peer := LocalPeer, connect_id := C} -> C
        after 1000 ->
            exit(local_peer_did_not_notify_worker)
        end,
    RemotePeer =
        receive
            #{peer := P, connect_id := ConnectID} -> P
        after 1000 ->
            exit(remote_peer_did_not_notify_worker)
        end,
    Ref1 = monitor(process, LocalPeer),
    Ref2 = monitor(process, RemotePeer),
    ok = enet:disconnect_peer(LocalPeer),
    receive
        {enet, disconnected, local, LocalPeer, ConnectID} -> ok
    after 1000 ->
        exit(local_peer_did_not_notify_worker)
    end,
    receive
        {enet, disconnected, remote, RemotePeer, ConnectID} -> ok
    after 1000 ->
        exit(remote_peer_did_not_notify_worker)
    end,
    receive
        {'DOWN', Ref1, process, LocalPeer, normal} -> ok
    after 1000 ->
        exit(local_peer_did_not_exit)
    end,
    receive
        {'DOWN', Ref2, process, RemotePeer, normal} -> ok
    after 1000 ->
        exit(remote_peer_did_not_exit)
    end,
    ok = enet:stop_host(LocalHost),
    ok = enet:stop_host(RemoteHost).

remote_disconnect_test(_Config) ->
    Self = self(),
    ConnectFun = fun(PeerInfo) ->
        Self ! PeerInfo,
        {ok, Self}
    end,
    {ok, LocalHost} = enet:start_host(0, ConnectFun, [{peer_limit, 8}]),
    {ok, RemoteHost} = enet:start_host(0, ConnectFun, [{peer_limit, 8}]),
    {ok, LocalPeer} = enet:connect_peer(LocalHost, "127.0.0.1", RemoteHost, 1),
    ConnectID =
        receive
            #{peer := LocalPeer, connect_id := C} -> C
        after 1000 ->
            exit(local_peer_did_not_notify_worker)
        end,
    RemotePeer =
        receive
            #{peer := P, connect_id := ConnectID} -> P
        after 1000 ->
            exit(remote_peer_did_not_notify_worker)
        end,
    Ref1 = monitor(process, LocalPeer),
    Ref2 = monitor(process, RemotePeer),
    ok = enet:disconnect_peer(RemotePeer),
    receive
        {enet, disconnected, local, _LocalPeer, ConnectID} -> ok
    after 1000 ->
        exit(local_peer_did_not_notify_worker)
    end,
    receive
        {enet, disconnected, remote, _RemotePeer, ConnectID} -> ok
    after 1000 ->
        exit(remote_peer_did_not_notify_worker)
    end,
    receive
        {'DOWN', Ref1, process, LocalPeer, normal} -> ok
    after 1000 ->
        exit(local_peer_did_not_exit)
    end,
    receive
        {'DOWN', Ref2, process, RemotePeer, normal} -> ok
    after 1000 ->
        exit(remote_peer_did_not_exit)
    end,
    ok = enet:stop_host(LocalHost),
    ok = enet:stop_host(RemoteHost).

unsequenced_messages_test(_Config) ->
    Self = self(),
    ConnectFun = fun(PeerInfo) ->
        Self ! PeerInfo,
        {ok, Self}
    end,
    {ok, LocalHost} = enet:start_host(0, ConnectFun, [{peer_limit, 8}]),
    {ok, RemoteHost} = enet:start_host(0, ConnectFun, [{peer_limit, 8}]),
    {ok, LocalPeer} = enet:connect_peer(LocalHost, "127.0.0.1", RemoteHost, 1),
    {ConnectID, LocalChannels} =
        receive
            #{peer := LocalPeer, channels := LCs, connect_id := C} -> {C, LCs}
        after 1000 ->
            exit(local_peer_did_not_notify_worker)
        end,
    RemoteChannels =
        receive
            #{channels := RCs, connect_id := ConnectID} -> RCs
        after 1000 ->
            exit(remote_peer_did_not_notify_worker)
        end,
    {ok, LocalChannel1} = maps:find(0, LocalChannels),
    {ok, RemoteChannel1} = maps:find(0, RemoteChannels),
    ok = enet:send_unsequenced(LocalChannel1, <<"local->remote">>),
    ok = enet:send_unsequenced(RemoteChannel1, <<"remote->local">>),
    receive
        {enet, 0, #unsequenced{data = <<"local->remote">>}} -> ok
    after 500 ->
        exit(remote_channel_did_not_send_data_to_worker)
    end,
    receive
        {enet, 0, #unsequenced{data = <<"remote->local">>}} -> ok
    after 500 ->
        exit(local_channel_did_not_send_data_to_worker)
    end,
    ok = enet:stop_host(LocalHost),
    ok = enet:stop_host(RemoteHost).

unreliable_messages_test(_Config) ->
    Self = self(),
    ConnectFun = fun(PeerInfo) ->
        Self ! PeerInfo,
        {ok, Self}
    end,
    {ok, LocalHost} = enet:start_host(0, ConnectFun, [{peer_limit, 8}]),
    {ok, RemoteHost} = enet:start_host(0, ConnectFun, [{peer_limit, 8}]),
    {ok, LocalPeer} = enet:connect_peer(LocalHost, "127.0.0.1", RemoteHost, 1),
    {ConnectID, LocalChannels} =
        receive
            #{peer := LocalPeer, channels := LCs, connect_id := C} -> {C, LCs}
        after 1000 ->
            exit(local_peer_did_not_notify_worker)
        end,
    RemoteChannels =
        receive
            #{channels := RCs, connect_id := ConnectID} -> RCs
        after 1000 ->
            exit(remote_peer_did_not_notify_worker)
        end,
    {ok, LocalChannel1} = maps:find(0, LocalChannels),
    {ok, RemoteChannel1} = maps:find(0, RemoteChannels),
    ok = enet:send_unreliable(LocalChannel1, <<"local->remote 1">>),
    ok = enet:send_unreliable(RemoteChannel1, <<"remote->local 1">>),
    ok = enet:send_unreliable(LocalChannel1, <<"local->remote 2">>),
    ok = enet:send_unreliable(RemoteChannel1, <<"remote->local 2">>),
    receive
        {enet, 0, #unreliable{data = <<"local->remote 1">>}} -> ok
    after 500 ->
        exit(remote_channel_did_not_send_data_to_worker)
    end,
    receive
        {enet, 0, #unreliable{data = <<"remote->local 1">>}} -> ok
    after 500 ->
        exit(local_channel_did_not_send_data_to_worker)
    end,
    receive
        {enet, 0, #unreliable{data = <<"local->remote 2">>}} -> ok
    after 500 ->
        exit(remote_channel_did_not_send_data_to_worker)
    end,
    receive
        {enet, 0, #unreliable{data = <<"remote->local 2">>}} -> ok
    after 500 ->
        exit(local_channel_did_not_send_data_to_worker)
    end,
    ok = enet:stop_host(LocalHost),
    ok = enet:stop_host(RemoteHost).

reliable_messages_test(_Config) ->
    Self = self(),
    ConnectFun = fun(PeerInfo) ->
        Self ! PeerInfo,
        {ok, Self}
    end,
    {ok, LocalHost} = enet:start_host(0, ConnectFun, [{peer_limit, 8}]),
    {ok, RemoteHost} = enet:start_host(0, ConnectFun, [{peer_limit, 8}]),
    {ok, LocalPeer} = enet:connect_peer(LocalHost, "127.0.0.1", RemoteHost, 1),
    {ConnectID, LocalChannels} =
        receive
            #{peer := LocalPeer, channels := LCs, connect_id := C} -> {C, LCs}
        after 1000 ->
            exit(local_peer_did_not_notify_worker)
        end,
    RemoteChannels =
        receive
            #{channels := RCs, connect_id := ConnectID} -> RCs
        after 1000 ->
            exit(remote_peer_did_not_notify_worker)
        end,
    {ok, LocalChannel1} = maps:find(0, LocalChannels),
    {ok, RemoteChannel1} = maps:find(0, RemoteChannels),
    ok = enet:send_reliable(LocalChannel1, <<"local->remote 1">>),
    ok = enet:send_reliable(RemoteChannel1, <<"remote->local 1">>),
    ok = enet:send_reliable(LocalChannel1, <<"local->remote 2">>),
    ok = enet:send_reliable(RemoteChannel1, <<"remote->local 2">>),
    receive
        {enet, 0, #reliable{data = <<"local->remote 1">>}} -> ok
    after 500 ->
        exit(remote_channel_did_not_send_data_to_worker)
    end,
    receive
        {enet, 0, #reliable{data = <<"remote->local 1">>}} -> ok
    after 500 ->
        exit(local_channel_did_not_send_data_to_worker)
    end,
    receive
        {enet, 0, #reliable{data = <<"local->remote 2">>}} -> ok
    after 500 ->
        exit(remote_channel_did_not_send_data_to_worker)
    end,
    receive
        {enet, 0, #reliable{data = <<"remote->local 2">>}} -> ok
    after 500 ->
        exit(local_channel_did_not_send_data_to_worker)
    end,
    ok = enet:stop_host(LocalHost),
    ok = enet:stop_host(RemoteHost).

unsequenced_broadcast_test(_Config) ->
    Self = self(),
    ConnectFun = fun(PeerInfo) ->
        Self ! PeerInfo,
        {ok, Self}
    end,
    {ok, Host1} = enet:start_host(0, ConnectFun, [{peer_limit, 8}]),
    {ok, Host2} = enet:start_host(0, ConnectFun, [{peer_limit, 8}]),
    {ok, Host3} = enet:start_host(0, ConnectFun, [{peer_limit, 8}]),
    {ok, Peer12} = enet:connect_peer(Host1, "127.0.0.1", Host2, 1),
    ConnectID12 =
        receive
            #{peer := Peer12, connect_id := CID12} -> CID12
        after 1000 ->
            exit(peer12_did_not_notify_worker)
        end,
    receive
        #{connect_id := ConnectID12} -> ok
    after 1000 ->
        exit(peer21_did_not_notify_worker)
    end,
    {ok, Peer23} = enet:connect_peer(Host2, "127.0.0.1", Host3, 1),
    ConnectID23 =
        receive
            #{peer := Peer23, connect_id := CID23} -> CID23
        after 1000 ->
            exit(peer23_did_not_notify_worker)
        end,
    receive
        #{connect_id := ConnectID23} -> ok
    after 1000 ->
        exit(peer32_did_not_notify_worker)
    end,
    {ok, Peer31} = enet:connect_peer(Host3, "127.0.0.1", Host1, 1),
    ConnectID31 =
        receive
            #{peer := Peer31, connect_id := CID31} -> CID31
        after 1000 ->
            exit(peer31_did_not_notify_worker)
        end,
    receive
        #{connect_id := ConnectID31} -> ok
    after 1000 ->
        exit(peer13_did_not_notify_worker)
    end,
    ok = enet:broadcast_unsequenced(Host1, 0, <<"host1->broadcast">>),
    ok = enet:broadcast_unsequenced(Host2, 0, <<"host2->broadcast">>),
    ok = enet:broadcast_unsequenced(Host3, 0, <<"host3->broadcast">>),
    receive
        {enet, 0, #unsequenced{data = <<"host1->broadcast">>}} -> ok
    after 500 ->
        exit(channel_did_not_send_data_to_worker)
    end,
    receive
        {enet, 0, #unsequenced{data = <<"host1->broadcast">>}} -> ok
    after 500 ->
        exit(channel_did_not_send_data_to_worker)
    end,
    receive
        {enet, 0, #unsequenced{data = <<"host2->broadcast">>}} -> ok
    after 500 ->
        exit(channel_did_not_send_data_to_worker)
    end,
    receive
        {enet, 0, #unsequenced{data = <<"host2->broadcast">>}} -> ok
    after 500 ->
        exit(channel_did_not_send_data_to_worker)
    end,
    receive
        {enet, 0, #unsequenced{data = <<"host3->broadcast">>}} -> ok
    after 500 ->
        exit(channel_did_not_send_data_to_worker)
    end,
    receive
        {enet, 0, #unsequenced{data = <<"host3->broadcast">>}} -> ok
    after 500 ->
        exit(channel_did_not_send_data_to_worker)
    end,
    ok = enet:stop_host(Host1),
    ok = enet:stop_host(Host2),
    ok = enet:stop_host(Host3).

unreliable_broadcast_test(_Config) ->
    Self = self(),
    ConnectFun = fun(PeerInfo) ->
        Self ! PeerInfo,
        {ok, Self}
    end,
    {ok, Host1} = enet:start_host(0, ConnectFun, [{peer_limit, 8}]),
    {ok, Host2} = enet:start_host(0, ConnectFun, [{peer_limit, 8}]),
    {ok, Host3} = enet:start_host(0, ConnectFun, [{peer_limit, 8}]),
    {ok, Peer12} = enet:connect_peer(Host1, "127.0.0.1", Host2, 1),
    ConnectID12 =
        receive
            #{peer := Peer12, connect_id := CID12} -> CID12
        after 1000 ->
            exit(peer12_did_not_notify_worker)
        end,
    receive
        #{connect_id := ConnectID12} -> ok
    after 1000 ->
        exit(peer21_did_not_notify_worker)
    end,
    {ok, Peer23} = enet:connect_peer(Host2, "127.0.0.1", Host3, 1),
    ConnectID23 =
        receive
            #{peer := Peer23, connect_id := CID23} -> CID23
        after 1000 ->
            exit(peer23_did_not_notify_worker)
        end,
    receive
        #{connect_id := ConnectID23} -> ok
    after 1000 ->
        exit(peer32_did_not_notify_worker)
    end,
    {ok, Peer31} = enet:connect_peer(Host3, "127.0.0.1", Host1, 1),
    ConnectID31 =
        receive
            #{peer := Peer31, connect_id := CID31} -> CID31
        after 1000 ->
            exit(peer31_did_not_notify_worker)
        end,
    receive
        #{connect_id := ConnectID31} -> ok
    after 1000 ->
        exit(peer13_did_not_notify_worker)
    end,
    ok = enet:broadcast_unreliable(Host1, 0, <<"host1->broadcast">>),
    ok = enet:broadcast_unreliable(Host2, 0, <<"host2->broadcast">>),
    ok = enet:broadcast_unreliable(Host3, 0, <<"host3->broadcast">>),
    receive
        {enet, 0, #unreliable{data = <<"host1->broadcast">>}} -> ok
    after 500 ->
        exit(channel_did_not_send_data_to_worker)
    end,
    receive
        {enet, 0, #unreliable{data = <<"host1->broadcast">>}} -> ok
    after 500 ->
        exit(channel_did_not_send_data_to_worker)
    end,
    receive
        {enet, 0, #unreliable{data = <<"host2->broadcast">>}} -> ok
    after 500 ->
        exit(channel_did_not_send_data_to_worker)
    end,
    receive
        {enet, 0, #unreliable{data = <<"host2->broadcast">>}} -> ok
    after 500 ->
        exit(channel_did_not_send_data_to_worker)
    end,
    receive
        {enet, 0, #unreliable{data = <<"host3->broadcast">>}} -> ok
    after 500 ->
        exit(channel_did_not_send_data_to_worker)
    end,
    receive
        {enet, 0, #unreliable{data = <<"host3->broadcast">>}} -> ok
    after 500 ->
        exit(channel_did_not_send_data_to_worker)
    end,
    ok = enet:stop_host(Host1),
    ok = enet:stop_host(Host2),
    ok = enet:stop_host(Host3).

reliable_broadcast_test(_Config) ->
    Self = self(),
    ConnectFun = fun(PeerInfo) ->
        Self ! PeerInfo,
        {ok, Self}
    end,
    {ok, Host1} = enet:start_host(0, ConnectFun, [{peer_limit, 8}]),
    {ok, Host2} = enet:start_host(0, ConnectFun, [{peer_limit, 8}]),
    {ok, Host3} = enet:start_host(0, ConnectFun, [{peer_limit, 8}]),
    {ok, Peer12} = enet:connect_peer(Host1, "127.0.0.1", Host2, 1),
    ConnectID12 =
        receive
            #{peer := Peer12, connect_id := CID12} -> CID12
        after 1000 ->
            exit(peer12_did_not_notify_worker)
        end,
    receive
        #{connect_id := ConnectID12} -> ok
    after 1000 ->
        exit(peer21_did_not_notify_worker)
    end,
    {ok, Peer23} = enet:connect_peer(Host2, "127.0.0.1", Host3, 1),
    ConnectID23 =
        receive
            #{peer := Peer23, connect_id := CID23} -> CID23
        after 1000 ->
            exit(peer23_did_not_notify_worker)
        end,
    receive
        #{connect_id := ConnectID23} -> ok
    after 1000 ->
        exit(peer32_did_not_notify_worker)
    end,
    {ok, Peer31} = enet:connect_peer(Host3, "127.0.0.1", Host1, 1),
    ConnectID31 =
        receive
            #{peer := Peer31, connect_id := CID31} -> CID31
        after 1000 ->
            exit(peer31_did_not_notify_worker)
        end,
    receive
        #{connect_id := ConnectID31} -> ok
    after 1000 ->
        exit(peer13_did_not_notify_worker)
    end,
    ok = enet:broadcast_reliable(Host1, 0, <<"host1->broadcast">>),
    ok = enet:broadcast_reliable(Host2, 0, <<"host2->broadcast">>),
    ok = enet:broadcast_reliable(Host3, 0, <<"host3->broadcast">>),
    receive
        {enet, 0, #reliable{data = <<"host1->broadcast">>}} -> ok
    after 500 ->
        exit(channel_did_not_send_data_to_worker)
    end,
    receive
        {enet, 0, #reliable{data = <<"host1->broadcast">>}} -> ok
    after 500 ->
        exit(channel_did_not_send_data_to_worker)
    end,
    receive
        {enet, 0, #reliable{data = <<"host2->broadcast">>}} -> ok
    after 500 ->
        exit(channel_did_not_send_data_to_worker)
    end,
    receive
        {enet, 0, #reliable{data = <<"host2->broadcast">>}} -> ok
    after 500 ->
        exit(channel_did_not_send_data_to_worker)
    end,
    receive
        {enet, 0, #reliable{data = <<"host3->broadcast">>}} -> ok
    after 500 ->
        exit(channel_did_not_send_data_to_worker)
    end,
    receive
        {enet, 0, #reliable{data = <<"host3->broadcast">>}} -> ok
    after 500 ->
        exit(channel_did_not_send_data_to_worker)
    end,
    ok = enet:stop_host(Host1),
    ok = enet:stop_host(Host2),
    ok = enet:stop_host(Host3).
