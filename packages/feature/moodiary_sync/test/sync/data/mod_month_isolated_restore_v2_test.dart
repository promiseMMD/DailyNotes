import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_sync/src/data/impl/local_archive.dart';
import 'package:moodiary_sync/src/data/mod_month_isolated_restore_v2.dart';
import 'package:moodiary_sync/src/data/mod_month_recovery_slot_v2.dart';
import 'package:moodiary_sync/src/data/mod_month_zip_generation_install_v2.dart';
import 'package:moodiary_sync/src/data/mod_month_private_restore_workspace_v2.dart';
import 'package:moodiary_sync/src/data/mod_month_android_restore_root_v2.dart';
import 'package:moodiary_sync/src/data/mod_month_restore_inventory_v2.dart';
import 'package:moodiary_sync/src/data/mod_month_stream_stage_v2.dart';
import 'package:moodiary_sync/src/data/mod_month_verified_manifest_v2.dart';
import 'package:moodiary_sync/src/data/mod_month_zip_bundle_v2.dart';
import 'package:moodiary_sync/src/data/mod_month_zip_preflight_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_verified_manifest_v1.dart' show ModBundleInvalid;

import '../sync_test_harness.dart';

const topicId='aac26e25-4a1d-4b4c-b256-9b0c347d36e2';
const ordinaryId='45c26e25-4a1d-4b4c-b256-9b0c347d36e2';
const categoryId='4ba27777-7a1d-4b4c-b256-9b0c347d36e2';
const placeId='9c9f1255-4a1d-4b4c-b256-9b0c347d36e2';
const blockId='entry-block-0001';
const rootId='revision-root-0001';
const movedId='revision-moved-0001';
const summaryId='summary-block-0001';
const summaryRevision='revision-summary-0001';

Uint8List utf(String text) => Uint8List.fromList(utf8.encode(text));
String digest(Object item) =>
  sha256.convert(utf8.encode(jsonEncode(item))).toString();

String doc(String content,{String? image}) => jsonEncode({
  'type':'doc','attrs':{'v':2},
  'content':[
    {'type':'paragraph','content':[{'type':'text','text':content}]},
    if (image!=null) {'type':'image','attrs':{'src':image}},
  ],
});

final class _PythonZipTransport implements ModMonthZipTransportV2 {
  const _PythonZipTransport();
  static Future<void> _python(List<String> args) async {
    final result=await Process.run('python3',args);
    if (result.exitCode!=0) throw StateError(
      'zip fixture failure: '+result.stderr.toString());
  }
  @override
  Future<void> create({
    required String archivePath,
    required String sourceDirectory,
    required List<String> entries,
  }) => _python(['-c',r'''
import os,sys,zipfile
dest,root,*items=sys.argv[1:]
with zipfile.ZipFile(dest,'w',allowZip64=True) as z:
    for name in items:
        z.write(os.path.join(root,*name.split('/')),arcname=name,
                compress_type=zipfile.ZIP_STORED)
''',archivePath,sourceDirectory,...entries]);

  @override
  Future<void> extract({
    required String archivePath,
    required String destinationDirectory,
  }) => _python(['-c',r'''
import sys,zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
''',archivePath,destinationDirectory]);
}

void main() {
  late Directory sandbox;
  late MoodiaryDatabase source;
  const transport=_PythonZipTransport();

  bool isTopic(Diary diary)=>diary.tags.contains('test-long-topic');

  setUp(() async {
    sandbox=await Directory.systemTemp.createTemp('w9842-restore-test-');
    source=MoodiaryDatabase.forTesting(NativeDatabase.memory());
    await source.customSelect('SELECT 1').get();
  });

  tearDown(() async {
    await source.close();
    if (await sandbox.exists()) await sandbox.delete(recursive:true);
  });

  Future<void> seedGraph() async {
    for (final month in ['2026-11','2026-12']) {
      await source.customStatement(
        'INSERT INTO mod_month_pages'
        '(topic_id,month_key,diary_id,created_ms) VALUES(?,?,?,?)',
        [topicId,month,null,100]);
    }
    for (final (block,month,kind) in [
      (blockId,'2026-11','entry'),(summaryId,'2026-11','summary'),
    ]) {
      await source.customStatement(
        'INSERT INTO mod_month_blocks'
        '(block_id,topic_id,month_key,kind,created_ms) VALUES(?,?,?,?,?)',
        [block,topicId,month,kind,101]);
    }
    Future<void> add({
      required String revision,
      required String block,
      String? parent,
      required String kind,
      required String month,
      String? day,
      required String content,
      bool deleted=false,
      required int time,
    }) async {
      await source.customStatement(
        'INSERT INTO mod_month_revisions'
        '(revision_id,block_id,parent_revision_id,month_key,day_key,'
        'occurred_at_ms,body_json,deleted,edited_at_ms)'
        ' VALUES(?,?,?,?,?,?,?,?,?)',
        [revision,block,parent,month,day,time,content,deleted?1:0,time+10]);
      await source.customStatement(
        'INSERT INTO mod_month_ops'
        '(operation_id,payload_sha256,block_id,revision_id,applied_at_ms)'
        ' VALUES(?,?,?,?,?)',
        ['operation-'+revision,
          digest([block,revision,topicId,month,kind,parent,day,time,
            content,deleted]),block,revision,time+10]);
    }
    await add(revision:rootId,block:blockId,kind:'entry',
      month:'2026-11',day:'2026-11-07',
      content:doc('跨月前内容',image:'history.png'),time:200);
    await add(revision:movedId,block:blockId,parent:rootId,kind:'entry',
      month:'2026-12',day:'2026-12-01',
      content:doc('删除但保留修订历史'),deleted:true,time:300);
    await add(revision:summaryRevision,block:summaryId,kind:'summary',
      month:'2026-11',content:doc('十一月总结'),time:400);
    for (final (block,revision) in [
      (blockId,movedId),(summaryId,summaryRevision),
    ]) {
      await source.customStatement(
        'INSERT INTO mod_month_heads(block_id,revision_id) VALUES(?,?)',
        [block,revision]);
    }
    // A moved and deleted entry retains BOTH day identities, plus the
    // local hidden flag from the original device.
    for (final (day,visibility) in [
      ('2026-11-07',0),('2026-12-01',1),
    ]) {
      await source.customStatement(
        'INSERT INTO mod_day_pages'
        '(topic_id,day_key,diary_id,visible_local,created_ms)'
        ' VALUES(?,?,NULL,?,?)',
        [topicId,day,visibility,500]);
    }
  }

  Future<String> buildZip() async {
    await seedGraph();
    final writer=await ModMonthStreamStageV2.create(
      sandbox.path+'/verified-directory');
    final media=Directory(sandbox.path+'/original-media');
    final current=File(media.path+'/image/current.png');
    final old=File(media.path+'/image/history.png');
    await current.parent.create(recursive:true);
    await current.writeAsBytes([137,80,78,71,1,1,2,3],flush:true);
    await old.writeAsBytes([137,80,78,71,9,8,7,6],flush:true);
    final topic=buildDiary(id:topicId,title:'长期记录主题',
      images:['current.png']).copyWith(tags:['test-long-topic']);
    final ordinary=buildDiary(id:ordinaryId,categoryId:categoryId,
      title:'普通日记',modifiedMs:123);
    final category=buildCategory(id:categoryId,name:'生活',modifiedMs:121);
    final place=Place(id:placeId,name:'某个地点',latitude:34.0,
      longitude:110.5,lastModified:DateTime.utc(2026,11,8));
    await LocalArchive.writeArchive(
      sink:writer,diaries:[topic,ordinary],categories:[category],
      places:[place],
      tombstones:[buildDiaryTombstone(
        'e24f1abe-1111-4444-8888-000000000001',modifiedMs:150)],
      mediaBaseDir:media.path);
    // Historical media must be included even after the latest revision was
    // deleted: the legacy diary media list alone is not sufficient.
    await writer.addLocalFile('media/image/history.png',old.path);
    await writer.addBytes(ModMonthVerifiedManifestV2.graphPath,
      utf(await ModMonthGraphArchiveV2.exportGraph(source)));
    final verified=await writer.publish(isTopic:isTopic);
    return ModMonthZipBundleV2.createVerified(
      sourceDirectory:verified,
      outputZip:sandbox.path+'/archive.zip',
      isTopic:isTopic,transport:transport);
  }

  Future<int> count(MoodiaryDatabase db,String table) async =>
    (await db.customSelect('SELECT COUNT(*) AS n FROM '+table)
      .getSingle()).read<int>('n');

  test('end-to-end ZIP installs as a verified V2 generation and removes preview',() async {
    final zip=await buildZip();
    final slot=await ModMonthRecoverySlotV2.createNew(
      sandbox.path+'/generation-slot');
    final selected=await ModMonthZipGenerationInstallV2.install(
      zipPath:zip,previewDirectory:sandbox.path+'/slot-preview',
      slot:slot,generationId:'generation_from_zip_2026',
      isTopic:isTopic,transport:transport);
    expect(selected.endsWith('/generation_from_zip_2026'),isTrue);
    expect(await Directory(sandbox.path+'/slot-preview').exists(),false);
    expect(await slot.currentDirectory(),selected);
    final db=MoodiaryDatabase.forTesting(NativeDatabase(
      File(selected+'/database/restored.sqlite')));
    expect(await count(db,'mod_day_pages'),2);
    expect(await count(db,'mod_month_revisions'),greaterThan(0));
    await db.close();
    expect(await File(selected+'/media/image/history.png').exists(),true);
  });


  test('ZIP-to-generation refuses an existing preview without modifying it',
      () async {
    final zip=await buildZip();
    final preview=Directory(sandbox.path+'/existing-preview');
    await preview.create();
    final keep=File(preview.path+'/keep.txt');
    await keep.writeAsString('keep-existing-data',flush:true);
    final slot=await ModMonthRecoverySlotV2.createNew(
      sandbox.path+'/existing-preview-slot');
    await expectLater(
      ModMonthZipGenerationInstallV2.install(
        zipPath:zip,previewDirectory:preview.path,slot:slot,
        generationId:'generation_preview_conflict_2026',
        isTopic:isTopic,transport:transport),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','preview_destination_exists')));
    expect(await keep.readAsString(),'keep-existing-data');
    expect(await slot.currentDirectory(),isNull);
  });

  test('ZIP-to-generation removes preview when restore checkpoint fails before promotion',
      () async {
    final zip=await buildZip();
    final preview=sandbox.path+'/restore-checkpoint-preview';
    final slot=await ModMonthRecoverySlotV2.createNew(
      sandbox.path+'/restore-checkpoint-slot');
    await expectLater(
      ModMonthZipGenerationInstallV2.install(
        zipPath:zip,previewDirectory:preview,slot:slot,
        generationId:'generation_restore_checkpoint_2026',
        isTopic:isTopic,transport:transport,
        checkpoint:(phase) async {
          if (phase=='restore:complete') {
            throw StateError('injected restore-to-slot handoff failure');
          }
        }),
      throwsA(isA<StateError>()));
    expect(await Directory(preview).exists(),false);
    expect(await slot.currentDirectory(),isNull);
  });

  test('ZIP-to-generation rolls back an interrupted copy and preserves the previous generation',
      () async {
    final zip=await buildZip();
    final oldReady=await ModMonthIsolatedRestoreV2
      .restoreZipToNewIsolatedDirectory(
        zipPath:zip,outputDirectory:sandbox.path+'/old-ready-copy',
        isTopic:isTopic,transport:transport);
    final slotPath=sandbox.path+'/copy-interruption-slot';
    final slot=await ModMonthRecoverySlotV2.createNew(slotPath);
    await slot.installVerified(
      sourceDirectory:oldReady,generationId:'generation_previous_2026');
    final previous=await slot.currentDirectory();
    expect(previous,isNotNull);
    await Directory(oldReady).delete(recursive:true);
    final preview=sandbox.path+'/copy-interruption-preview';
    await expectLater(
      ModMonthZipGenerationInstallV2.install(
        zipPath:zip,previewDirectory:preview,slot:slot,
        generationId:'generation_next_2026',
        isTopic:isTopic,transport:transport,
        checkpoint:(phase) async {
          if (phase=='slot:files_copied') {
            throw const ModSlotV2SimulatedProcessDeath('files_copied');
          }
        }),
      throwsA(isA<ModSlotV2SimulatedProcessDeath>()));
    expect(await Directory(preview).exists(),false);
    final reopened=await ModMonthRecoverySlotV2.openExisting(slotPath);
    await expectLater(
      reopened.currentDirectory(),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','restart_recovery_required')));
    expect(await reopened.recover(),'rolled_back');
    expect(await reopened.currentDirectory(),previous);
    expect(await File(previous!+'/media/image/history.png').exists(),true);
    expect(await Directory(
      slotPath+'/generations/.incoming-generation_next_2026').exists(),false);
  });

  test('ZIP-to-generation commits after pointer-write interruption and retains the previous generation',
      () async {
    final zip=await buildZip();
    final oldReady=await ModMonthIsolatedRestoreV2
      .restoreZipToNewIsolatedDirectory(
        zipPath:zip,outputDirectory:sandbox.path+'/old-ready-commit',
        isTopic:isTopic,transport:transport);
    final slotPath=sandbox.path+'/pointer-interruption-slot';
    final slot=await ModMonthRecoverySlotV2.createNew(slotPath);
    await slot.installVerified(
      sourceDirectory:oldReady,generationId:'generation_previous_2026');
    final previous=await slot.currentDirectory();
    expect(previous,isNotNull);
    await Directory(oldReady).delete(recursive:true);
    final preview=sandbox.path+'/pointer-interruption-preview';
    await expectLater(
      ModMonthZipGenerationInstallV2.install(
        zipPath:zip,previewDirectory:preview,slot:slot,
        generationId:'generation_next_2026',
        isTopic:isTopic,transport:transport,
        checkpoint:(phase) async {
          if (phase=='slot:pointer_written') {
            throw const ModSlotV2SimulatedProcessDeath('pointer_written');
          }
        }),
      throwsA(isA<ModSlotV2SimulatedProcessDeath>()));
    expect(await Directory(preview).exists(),false);
    final reopened=await ModMonthRecoverySlotV2.openExisting(slotPath);
    await expectLater(
      reopened.currentDirectory(),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','restart_recovery_required')));
    expect(await reopened.recover(),'committed');
    final active=await reopened.currentDirectory();
    expect(active,isNotNull);
    expect(active!.endsWith('/generation_next_2026'),isTrue);
    expect(await File(previous!+'/media/image/history.png').exists(),true);
    expect(await File(active+'/media/image/history.png').exists(),true);
  });

  test('ZIP-to-generation refuses duplicate generation IDs without overwriting existing data',
      () async {
    final zip=await buildZip();
    final oldReady=await ModMonthIsolatedRestoreV2
      .restoreZipToNewIsolatedDirectory(
        zipPath:zip,outputDirectory:sandbox.path+'/duplicate-ready',
        isTopic:isTopic,transport:transport);
    final slot=await ModMonthRecoverySlotV2.createNew(
      sandbox.path+'/duplicate-generation-slot');
    await slot.installVerified(
      sourceDirectory:oldReady,generationId:'generation_duplicate_2026');
    final previous=await slot.currentDirectory();
    expect(previous,isNotNull);
    await Directory(oldReady).delete(recursive:true);
    final preview=sandbox.path+'/duplicate-generation-preview';
    await expectLater(
      ModMonthZipGenerationInstallV2.install(
        zipPath:zip,previewDirectory:preview,slot:slot,
        generationId:'generation_duplicate_2026',
        isTopic:isTopic,transport:transport),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','generation_already_exists')));
    expect(await Directory(preview).exists(),false);
    expect(await slot.currentDirectory(),previous);
    expect(await File(previous!+'/media/image/history.png').exists(),true);
  });


  test('ZIP-to-generation protects foreign files added during the handoff',
      () async {
    final zip=await buildZip();
    final preview=sandbox.path+'/preview-with-foreign-user-file';
    final slot=await ModMonthRecoverySlotV2.createNew(
      sandbox.path+'/foreign-file-slot');
    final userNotes=File(preview+'/not-part-of-restore.txt');
    await expectLater(
      ModMonthZipGenerationInstallV2.install(
        zipPath:zip,previewDirectory:preview,slot:slot,
        generationId:'generation_foreign_data_2026',
        isTopic:isTopic,transport:transport,
        checkpoint:(phase) async {
          if (phase=='restore:complete') {
            await userNotes.writeAsString('important user notes',flush:true);
            throw StateError('simulated handoff fault');
          }
        }),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','preview_cleanup_unsafe')));
    expect(await userNotes.readAsString(),'important user notes');
    expect(await slot.currentDirectory(),isNull);
  });

  test('ZIP-to-generation rejects replaced symlink preview without deleting user data',
      () async {
    final zip=await buildZip();
    final preview=sandbox.path+'/preview-replaced-by-link';
    final protected=Directory(sandbox.path+'/real-user-diaries');
    await protected.create();
    final keep=File(protected.path+'/never-delete.txt');
    await keep.writeAsString('preserve-this-diary',flush:true);
    final slot=await ModMonthRecoverySlotV2.createNew(
      sandbox.path+'/symlink-swap-slot');
    await expectLater(
      ModMonthZipGenerationInstallV2.install(
        zipPath:zip,previewDirectory:preview,slot:slot,
        generationId:'generation_link_swap_2026',
        isTopic:isTopic,transport:transport,
        checkpoint:(phase) async {
          if (phase=='restore:complete') {
            await Directory(preview).rename(preview+'.original');
            await Link(preview).create(protected.path);
            throw StateError('simulated preview swap');
          }
        }),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','preview_cleanup_unsafe')));
    expect(await keep.readAsString(),'preserve-this-diary');
    expect(await FileSystemEntity.type(preview,followLinks:false),
      FileSystemEntityType.link);
    expect(await slot.currentDirectory(),isNull);
  });

  test('ZIP-to-generation rejects modified media before cleanup',() async {
    final zip=await buildZip();
    final preview=sandbox.path+'/preview-mutated-media';
    final slot=await ModMonthRecoverySlotV2.createNew(
      sandbox.path+'/mutated-media-slot');
    final media=File(preview+'/media/image/history.png');
    await expectLater(
      ModMonthZipGenerationInstallV2.install(
        zipPath:zip,previewDirectory:preview,slot:slot,
        generationId:'generation_media_change_2026',
        isTopic:isTopic,transport:transport,
        checkpoint:(phase) async {
          if (phase=='restore:complete') {
            await media.writeAsBytes([2,3,5,7,11,13,17,19,23],flush:true);
            throw StateError('simulated preview media modification');
          }
        }),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','preview_cleanup_unsafe')));
    expect(await media.readAsBytes(),
      orderedEquals([2,3,5,7,11,13,17,19,23]));
    expect(await slot.currentDirectory(),isNull);
  });


  test('ZIP-to-generation refuses a preview nested inside the isolated slot root',
      () async {
    final zip=await buildZip();
    final slot=await ModMonthRecoverySlotV2.createNew(
      sandbox.path+'/nested-preview-slot');
    final forbidden=slot.root+'/preview-child';
    await expectLater(
      ModMonthZipGenerationInstallV2.install(
        zipPath:zip,previewDirectory:forbidden,slot:slot,
        generationId:'generation_nested_preview_2026',
        isTopic:isTopic,transport:transport),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','preview_slot_path_overlap')));
    expect(await Directory(forbidden).exists(),false);
    expect(await slot.currentDirectory(),isNull);
    expect(await File(slot.root+'/slot-identity.json').exists(),true);
  });

  test('ZIP-to-generation refuses an alias through a symbolic-link parent',
      () async {
    final zip=await buildZip();
    final slot=await ModMonthRecoverySlotV2.createNew(
      sandbox.path+'/symlink-parent-slot');
    final alias=Link(sandbox.path+'/slot-alias');
    await alias.create(slot.root);
    await expectLater(
      ModMonthZipGenerationInstallV2.install(
        zipPath:zip,previewDirectory:alias.path+'/preview-child',slot:slot,
        generationId:'generation_alias_preview_2026',
        isTopic:isTopic,transport:transport),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','preview_slot_path_overlap')));
    expect(await Directory(slot.root+'/preview-child').exists(),false);
    expect(await slot.currentDirectory(),isNull);
    expect(await File(slot.root+'/slot-identity.json').exists(),true);
  });

  test('ZIP-to-generation refuses a preview whose parent cannot be resolved',
      () async {
    final zip=await buildZip();
    final slot=await ModMonthRecoverySlotV2.createNew(
      sandbox.path+'/missing-parent-slot');
    final forbidden=sandbox.path+'/absent-preview-parent/preview';
    await expectLater(
      ModMonthZipGenerationInstallV2.install(
        zipPath:zip,previewDirectory:forbidden,slot:slot,
        generationId:'generation_missing_parent_2026',
        isTopic:isTopic,transport:transport),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','preview_isolation_unverifiable')));
    expect(await Directory(sandbox.path+'/absent-preview-parent').exists(),false);
    expect(await slot.currentDirectory(),isNull);
  });


  test('private workspace installs a verified isolated ZIP and reopens cleanly',
      () async {
    final zip=await buildZip();
    final userFile=File(sandbox.path+'/unrelated-real-diary.txt');
    await userFile.writeAsString('must-preserve',flush:true);
    final workspace=await ModMonthPrivateRestoreWorkspaceV2.createNew(
      sandbox.path);
    expect(workspace.root.startsWith(sandbox.path+'/'),isTrue);
    final active=await workspace.install(
      zipPath:zip,generationId:'generation_workspace_2026',
      isTopic:isTopic,transport:transport);
    expect(active.endsWith('/generation_workspace_2026'),isTrue);
    expect(await Directory(workspace.root+'/preview').exists(),false);
    final reopened=await ModMonthPrivateRestoreWorkspaceV2.openExisting(
      applicationSupportDirectory:sandbox.path,
      workspaceDirectory:workspace.root);
    expect(await reopened.currentDirectory(),active);
    expect(await reopened.recover(),'clean');
    expect(await File(active+'/media/image/history.png').exists(),true);
    expect(await userFile.readAsString(),'must-preserve');
  });

  test('private workspace refuses a symlinked caller-provided root',() async {
    final alias=Link(sandbox.path+'/fake-app-support');
    await alias.create(sandbox.path);
    await expectLater(
      ModMonthPrivateRestoreWorkspaceV2.createNew(alias.path),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','private_root_not_regular_directory')));
    expect(await FileSystemEntity.type(alias.path,followLinks:false),
      FileSystemEntityType.link);
  });

  test('private workspace refuses forged identity before reading data',() async {
    final zip=await buildZip();
    final workspace=await ModMonthPrivateRestoreWorkspaceV2.createNew(
      sandbox.path);
    await File(workspace.root+'/workspace-identity.json')
      .writeAsString('{}',flush:true);
    await expectLater(
      workspace.install(
        zipPath:zip,generationId:'generation_forged_identity_2026',
        isTopic:isTopic,transport:transport),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','private_workspace_identity_invalid')));
    expect(await Directory(workspace.root+'/preview').exists(),false);
    expect(await File(zip).exists(),true);
  });

  test('private workspace never overwrites a foreign preview directory',
      () async {
    final zip=await buildZip();
    final workspace=await ModMonthPrivateRestoreWorkspaceV2.createNew(
      sandbox.path);
    final foreign=File(workspace.root+'/preview/foreign.txt');
    await foreign.parent.create(recursive:true);
    await foreign.writeAsString('private-record',flush:true);
    await expectLater(
      workspace.install(
        zipPath:zip,generationId:'generation_foreign_preview_2026',
        isTopic:isTopic,transport:transport),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','preview_destination_exists')));
    expect(await foreign.readAsString(),'private-record');
    expect(await workspace.currentDirectory(),isNull);
  });

  test('private workspace refuses archives located inside its own directory',
      () async {
    final zip=await buildZip();
    final workspace=await ModMonthPrivateRestoreWorkspaceV2.createNew(
      sandbox.path);
    final privateZip=await File(zip).copy(workspace.root+'/inside.zip');
    await expectLater(
      workspace.install(
        zipPath:privateZip.path,
        generationId:'generation_inside_zip_2026',
        isTopic:isTopic,transport:transport),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','private_restore_archive_inside_workspace')));
    expect(await privateZip.exists(),true);
    expect(await Directory(workspace.root+'/preview').exists(),false);
    expect(await workspace.currentDirectory(),isNull);
  });

  test('private workspace cannot reopen an unrelated path',() async {
    await expectLater(
      ModMonthPrivateRestoreWorkspaceV2.openExisting(
        applicationSupportDirectory:sandbox.path,
        workspaceDirectory:sandbox.path),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','private_workspace_outside_root')));
  });


  test('Android private root preserves unrelated diaries during ZIP recovery',
      () async {
    final zip=await buildZip();
    final keep=File(sandbox.path+'/database/moodiary.db');
    await keep.parent.create(recursive:true);
    await keep.writeAsString('unchanged-live-diary',flush:true);

    final root=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
        applicationSupportDirectory:sandbox.path);
    expect(root.root.endsWith(
        '/'+ModMonthPrivateRestoreRootV2.directoryName),isTrue);
    final workspace=await root.createNewWorkspace();
    final active=await workspace.install(
        zipPath:zip,generationId:'generation_android_root_2026',
        isTopic:isTopic,transport:transport);
    final reopenedRoot=await ModMonthPrivateRestoreRootV2
        .openExistingForSupport(applicationSupportDirectory:sandbox.path);
    final reopened=await reopenedRoot.openExistingWorkspace(workspace.root);
    expect(await reopened.currentDirectory(),active);
    expect(await File(active+'/media/image/history.png').exists(),true);
    expect(await keep.readAsString(),'unchanged-live-diary');
  });

  test('Android private root creation is idempotent without reusing workspaces',
      () async {
    final a=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
        applicationSupportDirectory:sandbox.path);
    final first=await a.createNewWorkspace();
    final record=File(first.root+'/non-restorable-user-note.txt');
    await record.writeAsString('do-not-delete',flush:true);

    final b=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
        applicationSupportDirectory:sandbox.path);
    final second=await b.createNewWorkspace();
    expect(first.root,isNot(second.root));
    expect(a.root,b.root);
    expect(await record.readAsString(),'do-not-delete');
    expect(await Directory(second.root).exists(),isTrue);
  });

  test('Android private root refuses an existing foreign unmarked directory',
      () async {
    final foreign=Directory(sandbox.path+'/' +
        ModMonthPrivateRestoreRootV2.directoryName);
    await foreign.create();
    final notes=File(foreign.path+'/my-contents.txt');
    await notes.writeAsString('preserve-original',flush:true);
    await expectLater(ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
        applicationSupportDirectory:sandbox.path),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code',
        'android_restore_private_root_identity_invalid')));
    expect(await notes.readAsString(),'preserve-original');
  });

  test('Android private root refuses a symlink alias without following it',
      () async {
    final foreign=Directory(sandbox.path+'/other-real-data');
    await foreign.create();
    final note=File(foreign.path+'/important.txt');
    await note.writeAsString('keep',flush:true);
    final link=Link(sandbox.path+'/' +
        ModMonthPrivateRestoreRootV2.directoryName);
    await link.create(foreign.path);
    await expectLater(ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
        applicationSupportDirectory:sandbox.path),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code',
        'android_restore_private_root_not_directory')));
    expect(await note.readAsString(),'keep');
    expect(await FileSystemEntity.type(link.path,followLinks:false),
        FileSystemEntityType.link);
  });

  test('Android private root refuses forged identity without altering files',
      () async {
    final root=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
        applicationSupportDirectory:sandbox.path);
    final userFile=File(root.root+'/foreign-user-file.txt');
    await userFile.writeAsString('important',flush:true);
    await File(root.root+'/private-root-identity.json')
        .writeAsString('{"format":"forged"}',flush:true);
    await expectLater(ModMonthPrivateRestoreRootV2.openExistingForSupport(
        applicationSupportDirectory:sandbox.path),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code',
        'android_restore_private_root_identity_invalid')));
    expect(await userFile.readAsString(),'important');
  });

  test('Android private root rejects untrusted external workspace on reopen',
      () async {
    final root=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
        applicationSupportDirectory:sandbox.path);
    final other=Directory(sandbox.path+'/other-not-a-workspace');
    await other.create();
    final important=File(other.path+'/keep.md');
    await important.writeAsString('untouched',flush:true);
    await expectLater(root.openExistingWorkspace(other.path),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','private_workspace_outside_root')));
    expect(await important.readAsString(),'untouched');
  });

  test('Android private root reopen never creates missing directories',
      () async {
    await expectLater(ModMonthPrivateRestoreRootV2.openExistingForSupport(
        applicationSupportDirectory:sandbox.path),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','android_restore_private_root_not_directory')));
    expect(await Directory(sandbox.path+'/' +
        ModMonthPrivateRestoreRootV2.directoryName).exists(),false);
  });

  test('Android private restore facade fails closed outside Android',() async {
    if (!Platform.isAndroid) {
      await expectLater(ModMonthAndroidPrivateRestoreV2.createNew(),
        throwsA(isA<ModBundleInvalid>().having(
          (e)=>e.code,'code','android_restore_unsupported_platform')));
    }
  });


  test('V2 inventory is empty without any restore workspaces',() async {
    final root=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
      applicationSupportDirectory:sandbox.path);
    final snapshot=await ModMonthRestoreInventoryV2.inspect(root);
    expect(snapshot.entries,isEmpty);
    expect(snapshot.requiresExplicitRetentionDecision,false);
    expect(snapshot.hasUnverifiedItems,false);
    expect(snapshot.knownBytes,0);
  });

  test('V2 inventory recognizes verified immutable generation without mutation',
      () async {
    final zip=await buildZip();
    final root=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
      applicationSupportDirectory:sandbox.path);
    final ws=await root.createNewWorkspace();
    final selected=await ws.install(
      zipPath:zip,generationId:'generation_inventory_2026',
      isTopic:isTopic,transport:transport);
    final proof=File(selected+'/media/image/history.png');
    final before=await proof.readAsBytes();
    final snap=await ModMonthRestoreInventoryV2.inspect(root);
    expect(snap.entries,hasLength(1));
    expect(snap.entries.single.state,ModRestoreInventoryStateV2.ready);
    expect(snap.entries.single.activeDirectory,selected);
    expect(snap.entries.single.bytes,greaterThan(before.length));
    expect(snap.entries.single.files,greaterThan(2));
    expect(snap.requiresExplicitRetentionDecision,true);
    expect(snap.hasUnverifiedItems,false);
    expect(await proof.readAsBytes(),orderedEquals(before));
    expect(await ws.currentDirectory(),selected);
  });

  test('V2 inventory keeps an interrupted journal without repairing it',
      () async {
    final root=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
      applicationSupportDirectory:sandbox.path);
    final ws=await root.createNewWorkspace();
    final journal=File(ws.root+'/generation-slot/recovery-journal.json');
    await journal.writeAsString('{"unresolved":"do-not-touch"}',flush:true);
    final before=await journal.readAsBytes();
    final scan=await ModMonthRestoreInventoryV2.inspect(root);
    expect(scan.entries.single.state,
      ModRestoreInventoryStateV2.recoveryRequired);
    expect(scan.hasUnverifiedItems,true);
    expect(await journal.readAsBytes(),orderedEquals(before));
  });

  test('V2 inventory refuses to own unknown user files',() async {
    final root=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
      applicationSupportDirectory:sandbox.path);
    final note=File(root.root+'/my-original-notes.txt');
    await note.writeAsString('keep this file',flush:true);
    final scan=await ModMonthRestoreInventoryV2.inspect(root);
    expect(scan.entries,hasLength(1));
    expect(scan.entries.single.state,
      ModRestoreInventoryStateV2.unrecognized);
    expect(scan.entries.single.bytes,isNull);
    expect(scan.requiresExplicitRetentionDecision,true);
    expect(await note.readAsString(),'keep this file');
  });

  test('V2 inventory preserves a symlink replacing a workspace',() async {
    final root=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
      applicationSupportDirectory:sandbox.path);
    final target=Directory(sandbox.path+'/actual-user-data');
    await target.create();
    final userFile=File(target.path+'/kept.txt');
    await userFile.writeAsString('never-remove',flush:true);
    final link=Link(root.root+'/.moodiary-v2-private-restore-link');
    await link.create(target.path);
    final snap=await ModMonthRestoreInventoryV2.inspect(root);
    expect(snap.entries.single.state,
      ModRestoreInventoryStateV2.unrecognized);
    expect(await userFile.readAsString(),'never-remove');
    expect(await FileSystemEntity.type(link.path,followLinks:false),
      FileSystemEntityType.link);
  });

  test('V2 inventory flags a replaced workspace identity and preserves bytes',
      () async {
    final root=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
      applicationSupportDirectory:sandbox.path);
    final ws=await root.createNewWorkspace();
    final marker=File(ws.root+'/workspace-identity.json');
    await marker.writeAsString('{}',flush:true);
    final result=await ModMonthRestoreInventoryV2.inspect(root);
    expect(result.entries.single.state,
      ModRestoreInventoryStateV2.needsReview);
    expect(result.entries.single.bytes,isNull);
    expect(await marker.readAsString(),'{}');
  });

  test('V2 inventory marks an unexpected preview for manual review',() async {
    final root=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
      applicationSupportDirectory:sandbox.path);
    final ws=await root.createNewWorkspace();
    final note=File(ws.root+'/preview/uncommitted-entry.txt');
    await note.parent.create(recursive:true);
    await note.writeAsString('do-not-clean',flush:true);
    final scan=await ModMonthRestoreInventoryV2.inspect(root);
    expect(scan.entries.single.state,
      ModRestoreInventoryStateV2.needsReview);
    expect(scan.entries.single.bytes,greaterThan(0));
    expect(await note.readAsString(),'do-not-clean');
  });

  test('V2 inventory preserves an unexpected file inside an owned workspace',
      () async {
    final root=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
      applicationSupportDirectory:sandbox.path);
    final ws=await root.createNewWorkspace();
    final unknown=File(ws.root+'/personal.txt');
    await unknown.writeAsString('kept',flush:true);
    final scan=await ModMonthRestoreInventoryV2.inspect(root);
    expect(scan.entries.single.state,
      ModRestoreInventoryStateV2.needsReview);
    expect(scan.hasUnverifiedItems,true);
    expect(await unknown.readAsString(),'kept');
  });

  test('full V2 ZIP cold restore: native Diary, two daily mappings, history and media',
      () async {
    final zip=await buildZip();
    final restored=await ModMonthIsolatedRestoreV2
      .restoreZipToNewIsolatedDirectory(
        zipPath:zip,outputDirectory:sandbox.path+'/new-device',
        isTopic:isTopic,transport:transport);
    expect(restored,sandbox.path+'/new-device');
    final state=jsonDecode(await File(restored+'/restore-state.json')
      .readAsString()) as Map;
    expect(state['phase'],'ready');
    expect(state['format'],'moodiary-v2-isolated-restore');
    expect(state['version'],2);
    final db=MoodiaryDatabase.forTesting(NativeDatabase(
      File(restored+'/database/restored.sqlite')));
    try {
      await db.customSelect('SELECT 1').get();
      expect(await count(db,'diaries'),2);
      expect(await count(db,'categories'),1);
      expect(await count(db,'places'),1);
      expect(await count(db,'diary_media'),1);
      expect(await count(db,'diary_tags'),1);
      expect(await count(db,'tombstones'),1);
      expect(await count(db,'mod_month_pages'),2);
      expect(await count(db,'mod_day_pages'),2);
      final days=await db.customSelect(
        'SELECT day_key,visible_local FROM mod_day_pages ORDER BY day_key').get();
      expect(days.map((r)=>r.read<String>('day_key')),
        ['2026-11-07','2026-12-01']);
      expect(days.map((r)=>r.read<int>('visible_local')),[0,1]);
      expect(await count(db,'mod_month_blocks'),2);
      expect(await count(db,'mod_month_revisions'),3);
      expect(await count(db,'mod_month_heads'),2);
      expect(await count(db,'mod_month_ops'),3);
      expect(await ModMonthGraphArchiveV2.exportGraph(db),
        await ModMonthGraphArchiveV2.exportGraph(source));
      final all=await DiaryRepository(db).getAllDiaries();
      expect(all.map((d)=>d.title),containsAll(['长期记录主题','普通日记']));
      expect(all.firstWhere((d)=>d.id==topicId).tags,['test-long-topic']);
      expect((await db.customSelect(
        'SELECT pushed_backends_json FROM tombstones').getSingle())
        .read<String>('pushed_backends_json'),'[]');
    } finally {
      await db.close();
    }
    expect(await File(restored+'/media/image/current.png').readAsBytes(),
      orderedEquals([137,80,78,71,1,1,2,3]));
    expect(await File(restored+'/media/image/history.png').readAsBytes(),
      orderedEquals([137,80,78,71,9,8,7,6]));
    expect(await Directory(restored+'/verified-input').exists(),isFalse);
  });

  test('fault injection at every restore boundary cleans private state',
      () async {
    final zip=await buildZip();
    for (final phase in [
      'source_verified','graph_restored','native_restored',
      'media_restored','readback_complete','before_publish',
    ]) {
      final target=sandbox.path+'/fail-'+phase;
      await expectLater(
        ModMonthIsolatedRestoreV2.restoreZipToNewIsolatedDirectory(
          zipPath:zip,outputDirectory:target,
          isTopic:isTopic,transport:transport,
          checkpoint:(value) async {
            if (value==phase) throw StateError('injected crash at '+phase);
          },
        ),
        throwsA(isA<StateError>()));
      expect(await Directory(target).exists(),isFalse,
        reason:'phase '+phase+' must never publish partial restore');
      final leftovers=await sandbox.list(followLinks:false)
        .where((entry)=>entry.path.contains('.moodiary-w9842-')).toList();
      expect(leftovers,isEmpty,reason:'no leaked restore staging at '+phase);
      expect(await File(zip).exists(),isTrue);
    }
  });

  test('pre-existing destination survives attempted restore intact',() async {
    final zip=await buildZip();
    final target=Directory(sandbox.path+'/already-has-diaries');
    await target.create();
    final old=File(target.path+'/diary.txt');
    await old.writeAsString('real user diary, never touch');
    await expectLater(
      ModMonthIsolatedRestoreV2.restoreZipToNewIsolatedDirectory(
        zipPath:zip,outputDirectory:target.path,
        isTopic:isTopic,transport:transport),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','restore_destination_exists')));
    expect(await old.readAsString(),'real user diary, never touch');
  });

  test('tampered ZIP is rejected before isolated DB is published',() async {
    final zip=await buildZip();
    final data=await File(zip).readAsBytes();
    final bad=File(sandbox.path+'/tampered.zip');
    await bad.writeAsBytes(data.sublist(0,data.length~/2));
    final output=sandbox.path+'/bad-output';
    await expectLater(
      ModMonthIsolatedRestoreV2.restoreZipToNewIsolatedDirectory(
        zipPath:bad.path,outputDirectory:output,
        isTopic:isTopic,transport:transport),
      throwsA(isA<ModBundleInvalid>()));
    expect(await Directory(output).exists(),isFalse);
  });

  test('second restore does not merge, replace, or overwrite the first',() async {
    final zip=await buildZip();
    final target=sandbox.path+'/once';
    await ModMonthIsolatedRestoreV2.restoreZipToNewIsolatedDirectory(
      zipPath:zip,outputDirectory:target,
      isTopic:isTopic,transport:transport);
    final before=await File(target+'/database/restored.sqlite').length();
    await expectLater(ModMonthIsolatedRestoreV2
      .restoreZipToNewIsolatedDirectory(
        zipPath:zip,outputDirectory:target,
        isTopic:isTopic,transport:transport),
      throwsA(isA<ModBundleInvalid>()));
    expect(await File(target+'/database/restored.sqlite').length(),before);
  });
  test('legacy V1 extractor refuses a genuine V2 archive before any restoration',() async {
    final zip=await buildZip();
    await expectLater(ModMonthZipPreflightV1.inspect(zip),
      throwsA(isA<ModBundleInvalid>()));
    expect(await Directory(sandbox.path+'/unintended').exists(),isFalse);
  });

  test('V2 cold restore fails closed when day graph is absent in the ZIP',() async {
    final zip=await buildZip();
    final broken=sandbox.path+'/no-v2-day-graph.zip';
    final result=await Process.run('python3',['-c',r'''
import sys,zipfile
src,dst=sys.argv[1:]
with zipfile.ZipFile(src) as inp,zipfile.ZipFile(dst,'w') as out:
  for obj in inp.infolist():
    if obj.filename=='structured/month-day-graph-v2.json': continue
    out.writestr(obj,inp.read(obj.filename))
''',zip,broken]);
    expect(result.exitCode,0,reason:result.stderr.toString());
    await expectLater(ModMonthIsolatedRestoreV2
      .restoreZipToNewIsolatedDirectory(
        zipPath:broken,outputDirectory:sandbox.path+'/forged-out',
        isTopic:isTopic,transport:transport),
      throwsA(isA<ModBundleInvalid>()));
    expect(await Directory(sandbox.path+'/forged-out').exists(),false);
  });

}
