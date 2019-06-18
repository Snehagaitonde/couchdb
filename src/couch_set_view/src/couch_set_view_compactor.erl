% -*- Mode: Erlang; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil -*- */

% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_set_view_compactor).

-include ("couch_db.hrl").
-include_lib("couch_set_view/include/couch_set_view.hrl").

-export([start_compact/3, start_compact/4, start_compact/6, cancel_compact/5]).

-define(SORTED_CHUNK_SIZE, 1024 * 1024).
-define(PORT_OPTS,
        [exit_status, use_stdio, stderr_to_stdout, {line, 4096}, binary]).

-record(acc, {
   changes = 0,
   total_changes
}).

-spec start_compact(atom(), binary(), binary()) -> {'ok', pid()} |
                                                   {'error', 'initial_build'}.
start_compact(Mod, SetName, DDocId) ->
    start_compact(Mod, SetName, DDocId, main).

-spec start_compact(atom(), binary(), binary(), set_view_group_type()) ->
                           {'ok', pid()} |
                           {'error', 'initial_build'}.
start_compact(Mod, SetName, DDocId, Type) ->
    start_compact(Mod, SetName, DDocId, Type, prod, []).

-spec start_compact(atom(), binary(), binary(),
                    set_view_group_type(), 'prod' | 'dev', list()) ->
                           {'ok', pid()} | {'error', 'initial_build'}.
start_compact(Mod, SetName, DDocId, Type, Category, UserTaskStatus) ->
    {ok, Pid} = get_group_pid(Mod, SetName, DDocId, Type, Category),
    gen_server:call(Pid, {start_compact, mk_compact_group(UserTaskStatus)}, infinity).



-spec cancel_compact(atom(), binary(), binary(), set_view_group_type(),
                     'prod' | 'dev') -> 'ok'.
cancel_compact(Mod, SetName, DDocId, Type, Category) ->
    {ok, Pid} = get_group_pid(Mod, SetName, DDocId, Type, Category),
    gen_server:call(Pid, cancel_compact).


%%=============================================================================
%% internal functions
%%=============================================================================

-spec mk_compact_group(list()) -> CompactGroupFun
  when CompactGroupFun :: fun((#set_view_group{},
                               #set_view_group{},
                               string(),
                               pid() | 'nil',
                               pid()) -> no_return()).
mk_compact_group(UserStatus) ->
    fun(Group, EmptyGroup, TmpDir, UpdaterPid, Owner) ->
        compact_group(Group, EmptyGroup, TmpDir, UpdaterPid, Owner, UserStatus)
    end.

-spec compact_group(#set_view_group{},
                    #set_view_group{},
                    string(),
                    pid() | 'nil',
                    pid(),
                    list()) -> no_return().
compact_group(Group0, EmptyGroup, TmpDir, UpdaterPid, Owner, UserStatus) ->
    #set_view_group{
        set_name = SetName,
        type = Type
    } = Group0,
    StartTime = os:timestamp(),

    case is_pid(UpdaterPid) of
    true ->
        MonRef = erlang:monitor(process, UpdaterPid),
        Ref = make_ref(),
        UpdaterPid ! {compactor_started, self(), Ref},
        Group = receive
        {Ref, {ok, Group2}} ->
            erlang:demonitor(MonRef, [flush]),
            Group2;
        {'DOWN', MonRef, _, _, {updater_finished, UpResult}} ->
            UpResult#set_view_updater_result.group;
        {'DOWN', MonRef, _, _, noproc} ->
            % updater just finished
            {ok, Group2} = gen_server:call(Owner, request_group, infinity),
            Group2;
        {'DOWN', MonRef, _, _, Reason2} ->
            exit({updater_died, Reason2})
        end;
    false ->
        Group = Group0
    end,

    #set_view_group{
        sig = GroupSig
    } = Group,

    #set_view_group{
        filepath = TargetFile,
        fd = Fd
    } = EmptyGroup,

    TotalChanges = total_kv_count(Group),
    Acc0 = #acc{total_changes = TotalChanges},

    DDocIds = couch_set_view_util:get_ddoc_ids_with_sig(SetName, Group),

    Status = merge_statuses(UserStatus, [
        {type, view_compaction},
        {set, SetName},
        {signature, ?l2b(couch_util:to_hex(GroupSig))},
        {design_documents, DDocIds},
        {changes_done, 0},
        {total_changes, TotalChanges},
        {indexer_type, Type},
        {progress, case TotalChanges of 0 -> 100; _ -> 0 end}
    ]),

    couch_task_status:add_task(Status),
    couch_task_status:set_update_frequency(5000),

    % Use native compactor for id_btrees and mapreduce views
    ok = couch_file:flush(Fd),
    {ok, NewGroup, _} = compact_btrees(Group, EmptyGroup, TargetFile, Acc0),
    ok = couch_file:refresh_eof(Fd),

    CleanupKVCount = TotalChanges - total_kv_count(NewGroup),
    CompactResult = #set_view_compactor_result{
        group = NewGroup#set_view_group{
            fd = Fd
        },
        cleanup_kv_count = CleanupKVCount
    },
    maybe_retry_compact(CompactResult, StartTime, TmpDir, Owner, 1).

merge_statuses(UserStatus, OurStatus) ->
    UserStatus0 =
        lists:filter(
            fun ({Key, _}) ->
                not lists:keymember(Key, 1, OurStatus)
            end, UserStatus),
    UserStatus0 ++ OurStatus.

maybe_retry_compact(CompactResult0, StartTime, TmpDir, Owner, Retries) ->
    NewGroup = CompactResult0#set_view_compactor_result.group,
    #set_view_group{
        set_name = SetName,
        name = DDocId,
        type = Type,
        fd = Fd
    } = NewGroup,
    CompactResult = CompactResult0#set_view_compactor_result{
        compact_time = timer:now_diff(os:timestamp(), StartTime) / 1000000
    },
    % For compaction retry testing purposes
    receive
    pause ->
        receive unpause -> ok end
    after 0 ->
        ok
    end,
    ok = couch_file:flush(Fd),
    case gen_server:call(Owner, {compact_done, CompactResult}, infinity) of
    ok ->
        ok;
    {update, MissingCount} ->
        {ok, {LogFiles, NewSeqs, NewPartVersions}} = gen_server:call(
            Owner, compact_log_files, infinity),
        ?LOG_INFO("Compactor for set view `~s`, ~s group `~s`, "
                  "applying delta of ~p changes (retry number ~p, "
                  "max # of log files per btree ~p)",
                  [SetName, Type, DDocId, MissingCount, Retries,
                   length(hd(LogFiles))]),
        [TotalChanges] = couch_task_status:get([total_changes]),
        TotalChanges2 = TotalChanges + MissingCount,
        couch_task_status:update([
            {total_changes, TotalChanges2},
            {changes_done, TotalChanges},
            {progress, (TotalChanges * 100) div TotalChanges2},
            {retry_number, Retries}
        ]),
        NewGroup2 = apply_log(NewGroup, LogFiles, NewSeqs, NewPartVersions, TmpDir),
        CompactResult2 = CompactResult0#set_view_compactor_result{
            group = NewGroup2
        },
        maybe_retry_compact(CompactResult2, StartTime, TmpDir, Owner, Retries + 1)
    end.


get_group_pid(Mod, SetName, DDocId, main, Category) ->
    Pid = couch_set_view:get_group_pid(Mod, SetName, DDocId, Category),
    {ok, Pid};
get_group_pid(Mod, SetName, DDocId, replica, Category) ->
    Pid = couch_set_view:get_group_pid(Mod, SetName, DDocId, Category),
    {ok, Group} = gen_server:call(Pid, request_group, infinity),
    case is_pid(Group#set_view_group.replica_pid) of
    true ->
        {ok, Group#set_view_group.replica_pid};
    false ->
        no_replica_group_found
    end.


update_task(#acc{total_changes = 0} = Acc, _ChangesInc) ->
    Acc;
update_task(#acc{changes = Changes, total_changes = Total} = Acc, ChangesInc) ->
    Changes2 = Changes + ChangesInc,
    couch_task_status:update([
        {changes_done, Changes2},
        {progress, (Changes2 * 100) div Total}
    ]),
    Acc#acc{changes = Changes2}.


total_kv_count(#set_view_group{id_btree = IdBtree, views = Views, mod = Mod}) ->
    {ok, <<IdCount:40, _/binary>>} = couch_btree:full_reduce(IdBtree),
    lists:foldl(
        fun(View, Acc) ->
            Acc + Mod:get_row_count(View)
        end,
        IdCount, Views).


apply_log(Group0, LogFiles, NewSeqs, NewPartVersions, TmpDir) ->
    #set_view_group{
        mod = Mod
    } = Group0,

    [IdMergeFiles | ViewLogFilesList] = LogFiles,
    IdMergeFile = merge_files(Group0, IdMergeFiles, TmpDir, true),
    ViewMergeFiles = lists:map(
      fun(ViewFiles) ->
        merge_files(Group0, ViewFiles, TmpDir, false)
    end, ViewLogFilesList),
    % `MergeFiles` is supplied to the native updater. For spatial views only
    % the ID b-tree is updated.
    MergeFiles = case Mod of
    mapreduce_view ->
        [IdMergeFile | ViewMergeFiles];
    spatial_view ->
        [IdMergeFile]
    end,

    % Remove spatial views since native updater cannot handle them
    Group = couch_set_view_util:remove_group_views(Group0, spatial_view),
    {ok, NewGroup0, _} = couch_set_view_updater_helper:update_btrees(
        Group, TmpDir, MergeFiles, ?SORTED_CHUNK_SIZE, true),

    % Add back spatial views
    NewGroup = couch_set_view_util:update_group_views(
        NewGroup0, Group0, spatial_view),

    ok = file2:delete(IdMergeFile),

    % The native compactor for the Id b-tree was run, now it's time to run the
    % Erlang compactor for the spatial views
    NewGroup2 = case Mod of
    mapreduce_view ->
        NewGroup;
    spatial_view ->
        ok = couch_file:refresh_eof(NewGroup#set_view_group.fd),
        Views = Mod:update_spatial(NewGroup#set_view_group.views,
            ViewMergeFiles, ?SORTED_CHUNK_SIZE),
        NewHeader = NewGroup#set_view_group.index_header,
        NewGroup#set_view_group{
            views = Views,
            index_header = NewHeader#set_view_index_header{
                view_states = [Mod:get_state(V#set_view.indexer) || V <- Views]
            }
        }
    end,

    Header = NewGroup2#set_view_group.index_header,
        lists:foreach(
          fun(LogFile) ->
            ok = file2:delete(LogFile)
          end, ViewMergeFiles),
    NewGroup2#set_view_group{
        index_header = Header#set_view_index_header{
            seqs = NewSeqs,
            partition_versions = NewPartVersions
        }
    }.

merge_files(_Group, [LogFile], _TmpDir, _IsIdFile) ->
    LogFile;

merge_files(Group, LogFiles, TmpDir, IsIdFile) ->
    case os:find_executable("couch_view_file_merger") of
    false ->
        FileMergerCmd = nil,
        throw(<<"couch_view_file_merger command not found">>);
    FileMergerCmd ->
        ok
    end,
    FileType = case IsIdFile of
    true ->
        "i";
    false ->
        case Group#set_view_group.mod of
        mapreduce_view ->
            "v";
        spatial_view ->
            "s"
        end
    end,
    NumFiles = length(LogFiles),
    Port = open_port({spawn_executable, FileMergerCmd}, ?PORT_OPTS),
    true = port_command(Port, [FileType, $\n]),
    % Spatial views need the tmp dir to sort the files before merging
    case FileType of
    "s" ->
        true = port_command(Port, [TmpDir, $\n]);
    _ ->
        ok
    end,
    true = port_command(Port, [integer_to_list(NumFiles), $\n]),
    ok = lists:foreach(
      fun(LogFile) ->
          true = port_command(Port, [LogFile, $\n])
      end, LogFiles),
    DestFile = couch_set_view_util:new_sort_file_path(TmpDir, compactor),
    true = port_command(Port, [DestFile, $\n]),
    try
        file_merger_wait_loop(Group, Port, []),
        DestFile
    catch Error ->
        file2:delete(DestFile),
        exit(Error)
    after
        catch port_close(Port)
    end.

file_merger_wait_loop(Group, Port, Acc) ->
    #set_view_group{
        set_name = SetName,
        name = DDocId,
        type = Type
    } = Group,
    receive
    {Port, {exit_status, 0}} ->
        ok;
    {Port, {exit_status, 1}} ->
        ?LOG_INFO("Set view `~s`, ~s group `~s`, file merger stopped successfully.",
                   [SetName, Type, DDocId]),
        exit(shutdown);
    {Port, {exit_status, Status}} ->
        throw({couch_view_file_merger, Status, ?l2b(Acc)});
    {Port, {data, {noeol, Data}}} ->
        file_merger_wait_loop(Group, Port, [Data | Acc]);
    {Port, {data, {eol, Data}}} ->
        Msg = ?l2b(lists:reverse([Data | Acc])),
        ErrorMsg = "Set view `~s`, ~s group `~s`, "
                   "received error from file merger: ~s",
        ErrorArgs = [SetName, Type, DDocId],
        _Msg2 = couch_set_view_util:log_port_error(Msg, ErrorMsg, ErrorArgs),
        file_merger_wait_loop(Group, Port, []);
    {Port, Error} ->
        throw({file_merger_error, Error});
    stop ->
        ?LOG_INFO("Set view `~s`, ~s group `~s`, sending stop message to file merger.",
                   [SetName, Type, DDocId]),
        port_command(Port, "exit"),
        file_merger_wait_loop(Group, Port, Acc)
    end.

% Compact a view group by rewriting all btrees to a new file
% Invokes a native view compacter process to do the compaction.
-spec compact_btrees(#set_view_group{}, #set_view_group{}, list(), #acc{}) ->
                                               {ok, #set_view_group{}, #acc{}}.
compact_btrees(Group, EmptyGroup, TargetFile, ResultAcc) ->
    case os:find_executable("couch_view_group_compactor") of
    false ->
        Cmd = nil,
        throw(<<"couch_view_group_compactor command not found">>);
    Cmd ->
        ok
    end,
    Options = [exit_status, use_stdio, stderr_to_stdout, stream, binary],
    Port = open_port({spawn_executable, Cmd}, Options),

    true = port_command(Port, [TargetFile, $\n]),

    true = port_command(Port, [integer_to_list(ResultAcc#acc.total_changes), $\n]),

    couch_set_view_util:send_group_info(Group, Port),

    ok = couch_set_view_util:send_group_header(Group, Port),

    {NewGroup, ResultAcc2} =
    try compact_btrees_wait_loop(Port, Group, EmptyGroup, <<>>, ResultAcc) of
    {ok, Resp} ->
        Resp
    catch
    Error ->
        exit(Error)
    after
        catch port_close(Port)
    end,
    {ok, NewGroup, ResultAcc2}.

compact_btrees_wait_loop(Port, Group, EmptyGroup, Acc0, ResultAcc) ->
    #set_view_group{
        set_name = SetName,
        name = DDocId,
        type = Type,
        mod = Mod
    } = Group,
    {Line, Acc} = couch_set_view_util:try_read_line(Acc0),
    case Line of
    nil ->
        receive
        {Port, {data, Data}} ->
            Acc2 = iolist_to_binary([Acc, Data]),
            compact_btrees_wait_loop(Port, Group, EmptyGroup, Acc2, ResultAcc);
        {Port, {exit_status, 0}} ->
            {ok, {Group, ResultAcc}};
        {Port, {exit_status, Status}} ->
            throw({view_group_index_compactor_exit, Status});
        {Port, Error} ->
            throw({view_group_index_compactor_error, Error})
        end;
    <<"Stats = ", Data/binary>> ->
        % Read incremental stats progress update
        {ok, [Inserts], []} = io_lib:fread("inserted : ~d", binary_to_list(Data)),
        ResultAcc2 = update_task(ResultAcc, Inserts),
        compact_btrees_wait_loop(Port, Group, EmptyGroup, Acc, ResultAcc2);
    <<"Header Len : ", Data/binary>> ->
        % Read resulting group from stdout
        {ok, [HeaderLen], []} = io_lib:fread("~d", binary_to_list(Data)),
        {NewGroup, Acc2} =
        case couch_set_view_util:receive_group_header(Port, HeaderLen, Acc) of
        {ok, HeaderBin, Rest} ->
            #set_view_group{
                id_btree = IdBtree,
                views = Views
            } = EmptyGroup,
            Header  = couch_set_view_util:header_bin_to_term(HeaderBin),
            #set_view_index_header{
                id_btree_state = NewIdBtreeRoot,
                view_states = NewViewRoots
            } = Header,
            NewIdBtree = couch_btree:set_state(IdBtree, NewIdBtreeRoot),
            NewViews = lists:zipwith(
                fun(#set_view{indexer = View} = V, NewRoot) ->
                    NewView = Mod:set_state(View, NewRoot),
                    V#set_view{indexer = NewView}
                end,
                Views, NewViewRoots),

            NewGroup0 = EmptyGroup#set_view_group{
                id_btree = NewIdBtree,
                views = NewViews,
                index_header = Header
            },
            {NewGroup0, Rest};
        {error, Error, Rest} ->
            self() ! Error,
            {Group, Rest}
        end,
        compact_btrees_wait_loop(Port, NewGroup, EmptyGroup, Acc2, ResultAcc);
    <<"Results = ", Data/binary>> ->
        % Read resulting stats from stdout
        {ok, [Inserts], []} = io_lib:fread("inserts : ~d", binary_to_list(Data)),
        ?LOG_INFO("Set view `~s`, ~s group `~s`, view compactor inserted ~p kvs.",
                   [SetName, Type, DDocId, Inserts]),
        compact_btrees_wait_loop(Port, Group, EmptyGroup, Acc, ResultAcc);
    Msg ->
        ?LOG_ERROR("Set view `~s`, ~s group `~s`, received error from index compactor: ~s",
                   [SetName, Type, DDocId, ?LOG_USERDATA(Msg)]),
        compact_btrees_wait_loop(Port, Group, EmptyGroup, <<>>, ResultAcc)
    end.
