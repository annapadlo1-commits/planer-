import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const LOCAL_CONTAINER = 'supabase_db_aud003-local-db-20260903';
export const LOCAL_PROJECT = 'aud003-local-db-20260903';
export const LOCAL_IMAGE = 'sha256:28f0e16a019e648089fc1a6d333549a55548f6019c15ae4bd7cd58b989027518';
export const LOCAL_CONTEXT = 'desktop-linux';
export const docker = process.env.AUD003_DOCKER_BINARY || 'docker';
export function dockerRead(args) {
 const r = spawnSync(docker,args,{encoding:'utf8',maxBuffer:8*1024*1024});
 assert.equal(r.status,0,`LOCAL_DOCKER_COMMAND_FAILED:${args[0]}`);
 return r.stdout;
}
export function inspectLocalTarget({requireRunning=true}={}) {
 assert.ok(!process.env.DOCKER_HOST, 'DOCKER_HOST_MUST_BE_UNSET');
 assert.ok(!process.env.DOCKER_CONTEXT || process.env.DOCKER_CONTEXT===LOCAL_CONTEXT, 'REMOTE_DOCKER_CONTEXT_REFUSED');
 assert.equal(dockerRead(['context','show']).trim(),LOCAL_CONTEXT);
 const [context]=JSON.parse(dockerRead(['context','inspect',LOCAL_CONTEXT]));
 assert.equal(context.Endpoints.docker.Host,'npipe:////./pipe/dockerDesktopLinuxEngine');
 const [state]=JSON.parse(dockerRead(['--context',LOCAL_CONTEXT,'inspect',LOCAL_CONTAINER]));
 assert.equal(state.Id,'33197cfa244a28049ce0166bffb5ae167d07e69f62e4fd209f578d4bc90d9864');
 assert.equal(state.Name,`/${LOCAL_CONTAINER}`);
 assert.equal(state.Config.Labels['com.supabase.cli.project'],LOCAL_PROJECT);
 assert.equal(state.Config.Image,LOCAL_IMAGE);
 assert.deepEqual(state.HostConfig.PortBindings,{'5432/tcp':[{HostIp:'127.0.0.1',HostPort:'55432'}]});
 assert.equal(state.HostConfig.NetworkMode,'aud003-local-only-20260903');
 assert.equal(state.HostConfig.Privileged,false);
 assert.equal(state.HostConfig.PidMode,'');
 assert.equal(state.Mounts.length,1);
 assert.equal(state.Mounts[0].Type,'volume');
 assert.equal(state.Mounts[0].Name,LOCAL_CONTAINER);
 assert.equal(state.Mounts[0].Destination,'/var/lib/postgresql/data');
 if (/nhthrtpkfpmufmrmdyjg|bdybebzvzapihjdauehg|supabase\.co|pooler\.supabase/iu.test(JSON.stringify(state.Config))) throw Error('REMOTE_CONFIGURATION_REFUSED');
 if (requireRunning) {
   assert.equal(state.State.Running,true);
   assert.equal(state.State.Health.Status,'healthy');
   assert.deepEqual(state.NetworkSettings.Ports,{'5432/tcp':[{HostIp:'127.0.0.1',HostPort:'55432'}]});
 }
 const [image]=JSON.parse(dockerRead(['--context',LOCAL_CONTEXT,'image','inspect',state.Image]));
 assert.equal(image.Id,LOCAL_IMAGE);
 const [volume]=JSON.parse(dockerRead(['--context',LOCAL_CONTEXT,'volume','inspect',LOCAL_CONTAINER]));
 assert.equal(volume.Name,LOCAL_CONTAINER);
 assert.equal(volume.Driver,'local');
 assert.ok(!volume.Options || Object.keys(volume.Options).length===0,'REMOTE_VOLUME_REFUSED');
 return {readAtUtc:new Date().toISOString(),context:LOCAL_CONTEXT,daemonEndpoint:context.Endpoints.docker.Host,dockerHostUnset:!process.env.DOCKER_HOST,
  containerId:state.Id,container:LOCAL_CONTAINER,imageId:image.Id,repoDigests:image.RepoDigests,volume:volume.Name,volumeDriver:volume.Driver,
  network:state.HostConfig.NetworkMode,portBindings:state.HostConfig.PortBindings,running:state.State.Running,health:state.State.Health?.Status,
  createdAt:state.Created,startedAt:state.State.StartedAt,finishedAt:state.State.FinishedAt,
  startupCommandSha256:createHash('sha256').update(JSON.stringify(state.Config.Cmd)).digest('hex'),
  sqlConnection:'docker exec -> psql -h /var/run/postgresql -> local Unix-domain socket; no host TCP/tunnel used'};
}
if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
 console.log(JSON.stringify(inspectLocalTarget({requireRunning:!process.argv.includes('--allow-stopped')}),null,2));
 if(process.argv.includes('--exposure-metadata')) {
  const [old]=JSON.parse(dockerRead(['--context',LOCAL_CONTEXT,'inspect',`${LOCAL_CONTAINER}-before-loopback`]));
  assert.equal(old.Config.Labels['com.supabase.cli.project'],LOCAL_PROJECT);
  console.log(JSON.stringify({incident:'INC-2026-09-03-002',containerId:old.Id,createdAt:old.Created,startedAt:old.State.StartedAt,finishedAt:old.State.FinishedAt,running:old.State.Running,configuredBindings:old.HostConfig.PortBindings},null,2));
 }
}
