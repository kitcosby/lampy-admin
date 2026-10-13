# Lampy Windows Administrator
# Single-file admin dashboard for the Lampy WSL stack.
# Runs on Windows, talks to the lampy distro via wsl.exe.
#
# Usage: powershell -ExecutionPolicy Bypass -File .\lampy-admin-win.ps1
# Then open http://127.0.0.1:8899/ (opens automatically).
# Ctrl+C to stop.
#
# Binds to 127.0.0.1 only: reachable from this Windows machine alone.
# All service commands run as root inside the lampy distro via wsl.exe.

$port = 8899
$distro = "lampy"

# --- Service definitions ---
# type supervisor  -> supervisorctl -c /etc/supervisor/conf.d/lampy.conf
# type postgres    -> pg_ctl as the postgres user (not under supervisord)
$services = @(
    @{ name = "apache2";    label = "Apache HTTPD";  type = "supervisor" },
    @{ name = "postgres";   label = "PostgreSQL 16"; type = "postgres"   },
    @{ name = "ollama";     label = "Ollama LLM";    type = "supervisor" },
    @{ name = "forum";      label = "Forum app";     type = "supervisor" },
    @{ name = "bible";      label = "Bible site";    type = "supervisor" },
    @{ name = "codeserver"; label = "code-server";   type = "supervisor" }
)

function Test-DistroVisible {
    # wsl.exe emits trailing CRs; trim each line and compare exactly
    $list = wsl --list --quiet 2>&1 | ForEach-Object { "$_".Trim() }
    return $list -contains $distro
}

function Invoke-Distro($bashCmd) {
    # Run a bash command as root in the distro, return trimmed stdout
    $out = wsl -d $distro -u root -- bash -c $bashCmd 2>&1 | Out-String
    return $out.Trim()
}

# Fail fast with a clear message if this Windows user can't see the distro
# (WSL distros are registered per-user under HKCU).
if (-not (Test-DistroVisible)) {
    Write-Output ""
    Write-Output "ERROR: WSL distro '$distro' is not visible to Windows user '$env:USERNAME'."
    Write-Output "WSL distros are registered per Windows user. Run this script as the user"
    Write-Output "that owns the '$distro' distro (the user who ran the Lampy installer)."
    Write-Output ""
    exit 1
}

function Get-SupervisorStatus($name) {
    $raw = Invoke-Distro "supervisorctl -c /etc/supervisor/conf.d/lampy.conf status $name"
    # e.g. "apache2  RUNNING  pid 380, uptime 0:00:11" or "apache2  STOPPED ..." or "FATAL ..."
    if ($raw -match '^\S+\s+(RUNNING|STOPPED|STARTING|BACKOFF|STOPPING|EXITED|FATAL|UNKNOWN)\b') {
        return $Matches[1]
    }
    return "UNKNOWN"
}

function Get-PostgresStatus {
    $raw = Invoke-Distro "su postgres -c '/usr/local/pgsql/bin/pg_isready'"
    if ($raw -match 'accepting connections') { return "RUNNING" }
    return "STOPPED"
}

function Get-ServiceStatus($svc) {
    if ($svc.type -eq "postgres") { return Get-PostgresStatus }
    return Get-SupervisorStatus $svc.name
}

function Start-ServiceLampy($svc) {
    if ($svc.type -eq "postgres") {
        # Clear a stale postmaster.pid if postgres isn't actually running,
        # then start. (Log file is postgres-owned; fixed 2026-10-08.)
        return Invoke-Distro "if ! ps aux | grep -q '[p]ostgres'; then rm -f /var/lib/postgresql/data/postmaster.pid; fi; su postgres -c '/usr/local/pgsql/bin/pg_ctl -D /var/lib/postgresql/data -l /var/log/postgresql.log start'"
    }
    if ($svc.name -eq "apache2") {
        # Apache leaves a stale pid file and occasionally a zombie holding port 80
        # after unclean stops; clear both before asking supervisord to start it.
        return Invoke-Distro "pkill -9 apache2 2>/dev/null; sleep 1; rm -f /var/run/apache2/apache2.pid; supervisorctl -c /etc/supervisor/conf.d/lampy.conf start apache2"
    }
    return Invoke-Distro "supervisorctl -c /etc/supervisor/conf.d/lampy.conf start $($svc.name)"
}

function Stop-ServiceLampy($svc) {
    if ($svc.type -eq "postgres") {
        return Invoke-Distro "su postgres -c '/usr/local/pgsql/bin/pg_ctl -D /var/lib/postgresql/data stop -m fast'"
    }
    return Invoke-Distro "supervisorctl -c /etc/supervisor/conf.d/lampy.conf stop $($svc.name)"
}

function Invoke-PgQuery($db, $sql) {
    # Run SQL via the lampy-pg.py helper as the postgres superuser.
    # Base64-wrapped so quoting survives PowerShell -> wsl -> bash -> su.
    # Returns the helper's JSON string (columns/rows/rowcount/error).
    $req = @{db=$db; sql=$sql} | ConvertTo-Json -Compress
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($req))
    $cmd = "echo $b64 | base64 -d | su postgres -c '/usr/bin/python3 /usr/local/bin/lampy-pg.py'"
    $out = wsl -d $distro -u root -- bash -c $cmd 2>&1 | Out-String
    return $out.Trim()
}

function Invoke-Psql($db, $cmd) {
    # Run a psql command (SQL or meta-command like \dt) via the psql CLI,
    # which understands meta-commands that psycopg2 cannot. Command goes
    # over stdin (base64-wrapped). Returns a JSON string {output|error}.
    # Shell escapes (\!) are blocked; db name is strictly validated.
    if ($db -notmatch '^[a-zA-Z0-9_]+$') {
        return (@{ error = "bad database name" } | ConvertTo-Json)
    }
    if ($cmd -match '(?m)^\s*\\!') {
        return (@{ error = "shell escapes (\\!) are blocked" } | ConvertTo-Json)
    }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cmd))
    $psql = "echo $b64 | base64 -d | su postgres -c '/usr/local/pgsql/bin/psql -X -q -d $db'"
    $out = wsl -d $distro -u root -- bash -c $psql 2>&1 | Out-String
    return (@{ output = $out.Trim() } | ConvertTo-Json)
}

function Get-IpConfig {    $winHost = $env:COMPUTERNAME
    $winIps = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
        Select-Object -ExpandProperty IPAddress) -join ', '
    $tailscale = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like '100.*' } |
        Select-Object -ExpandProperty IPAddress -First 1)
    $distroIp = Invoke-Distro "hostname -I"
    # reachability: can Windows HTTP reach the distro?
    $reachLocal = $false; $reachDistro = $false
    try { (Invoke-WebRequest -Uri 'http://127.0.0.1/' -UseBasicParsing -TimeoutSec 4).StatusCode | Out-Null; $reachLocal = $true } catch {}
    if ($distroIp) {
        try { (Invoke-WebRequest -Uri "http://$($distroIp.Split()[0])/" -UseBasicParsing -TimeoutSec 4).StatusCode | Out-Null; $reachDistro = $true } catch {}
    }
    return @{
        windowsHost   = $winHost
        windowsIps    = $winIps
        tailscaleIp   = $tailscale
        distroIp      = $distroIp
        reachLocalhost = $reachLocal
        reachDistroIp  = $reachDistro
    }
}

# --- HTTP server ---
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$listener.Start()
Write-Output "Lampy Admin running at http://127.0.0.1:$port/  (Ctrl+C to stop)"
Start-Process "http://127.0.0.1:$port/"

$dashboardHtml = @'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Lampy Admin</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;background:#1e1e1e;color:#ddd;margin:0;padding:20px}
h1{color:#fff;font-size:22px;margin:0 0 4px}h2{color:#fff;font-size:16px;margin:24px 0 8px}
.sub{color:#888;font-size:12px;margin-bottom:16px}
.card{background:#2d2d2d;border-radius:8px;padding:14px 16px;margin-bottom:12px}
table{width:100%;border-collapse:collapse}
th{text-align:left;color:#888;font-size:12px;padding:6px 8px;border-bottom:1px solid #444}
td{padding:8px;border-bottom:1px solid #333;font-size:14px}
.badge{display:inline-block;padding:2px 10px;border-radius:12px;font-size:12px;font-weight:600}
.ok{background:#1a4d1a;color:#7dffa7}.bad{background:#4d1a1a;color:#ff8d7d}.warn{background:#4d3d1a;color:#ffd97d}
button{background:#0e639c;color:#fff;border:0;border-radius:6px;padding:6px 14px;font-size:13px;cursor:pointer;margin-right:6px}
button:hover{background:#1177bb}button.stop{background:#8c2b2b}button.stop:hover{background:#a53434}
button:disabled{opacity:.4;cursor:default}
.kv{display:grid;grid-template-columns:200px 1fr;gap:4px 12px;font-size:14px}
.kv b{color:#aaa;font-weight:600}
#msg{color:#ffd97d;font-size:13px;min-height:18px;margin-top:8px}
.refresh{float:right;font-size:12px;color:#888}
</style></head><body>
<h1>Lampy Administrator</h1>
<div class="sub">Windows-side control panel for the Lampy WSL stack &mdash; via wsl.exe</div>

<h2>Network (IPconfig)</h2>
<div class="card"><div class="kv" id="ipconfig"><div>Loading…</div></div></div>

<h2>Services <span class="refresh"><button onclick="loadServices()">Refresh</button></span></h2>
<div class="card"><table>
<tr><th>Service</th><th>Status</th><th>Action</th></tr>
<tbody id="services"><tr><td colspan="3">Loading…</td></tr></tbody>
</table><div id="msg"></div>
</div>

<script>
function badge(s){
  if(s==='RUNNING')return '<span class="badge ok">RUNNING</span>';
  if(s==='STOPPED')return '<span class="badge bad">STOPPED</span>';
  return '<span class="badge warn">'+s+'</span>';
}
async function loadIp(){
  const r=await fetch('/api/ipconfig');const j=await r.json();
  const row=(k,v)=>'<b>'+k+'</b><div>'+(v||'—')+'</div>';
  document.getElementById('ipconfig').innerHTML=
    row('Windows host',j.windowsHost)+row('Windows IPs',j.windowsIps)+
    row('Tailscale IP',j.tailscaleIp)+row('Distro IP (lampy)',j.distroIp)+
    row('Windows -> localhost:80',j.reachLocalhost?'reachable':'<span class="badge bad">unreachable</span>')+
    row('Windows -> distro IP:80',j.reachDistroIp?'reachable':'<span class="badge bad">unreachable</span>');
}
async function loadServices(){
  const r=await fetch('/api/services');const j=await r.json();
  document.getElementById('services').innerHTML=j.map(s=>{
    const running=s.status==='RUNNING';
    return '<tr><td>'+s.label+'</td><td>'+badge(s.status)+'</td><td>'+
      '<button '+(running?'disabled':'')+' onclick="toggleService(\''+s.name+'\',\'start\')">Start</button>'+
      '<button class="stop" '+(!running?'disabled':'')+' onclick="toggleService(\''+s.name+'\',\'stop\')">Stop</button>'+
      '</td></tr>';
  }).join('');
}
async function toggleService(name,action){
  document.getElementById('msg').textContent=action+'ing '+name+'…';
  const r=await fetch('/api/service/'+name+'/'+action,{method:'POST'});
  const j=await r.json();
  document.getElementById('msg').textContent=j.result||j.error||'done';
  setTimeout(loadServices,2500);
}
loadIp();loadServices();setInterval(loadServices,15000);
</script>

<h2>PostgreSQL Admin</h2>
<div class="card">
<div style="margin-bottom:10px">
<label>Database: <select id="pgdb" onchange="loadPgAll()"></select></label>
<button onclick="loadPgAll()">Refresh</button>
<span id="pginfo" style="color:#888;font-size:12px;margin-left:12px"></span>
</div>
<h3 style="color:#fff;font-size:14px;margin:12px 0 6px">Tables</h3>
<table><tr><th>Schema</th><th>Table</th><th>Size</th><th>Est. rows</th></tr>
<tbody id="pgtables"><tr><td colspan="4">Loading…</td></tr></tbody></table>
<h3 style="color:#fff;font-size:14px;margin:12px 0 6px">Query</h3>
<textarea id="pgsq1" rows="4" style="width:100%;background:#1a1a1a;color:#ddd;border:1px solid #444;border-radius:6px;padding:8px;font-family:Consolas,monospace;font-size:13px">SELECT * FROM </textarea>
<div style="margin:8px 0"><button onclick="runPgQuery()">Run query</button><span id="pgmsg" style="color:#ffd97d;font-size:13px;margin-left:10px"></span></div>
<div style="overflow-x:auto"><table id="pgresults"></table></div>
<h3 style="color:#fff;font-size:14px;margin:12px 0 6px">PSQL Console</h3>
<div id="psqlout" style="background:#0a0a0a;color:#c8e6c9;border:1px solid #444;border-radius:6px;padding:10px;height:300px;overflow-y:auto;font-family:Consolas,monospace;font-size:13px;white-space:pre-wrap"></div>
<div style="margin-top:8px;display:flex;gap:8px">
<input id="psqlin" style="flex:1;background:#1a1a1a;color:#ddd;border:1px solid #444;border-radius:6px;padding:8px;font-family:Consolas,monospace;font-size:13px" placeholder="psql command, e.g. \dt  or  SELECT count(*) FROM words;  (uses database above)">
<button onclick="runPsql()">Run</button>
</div>
</div>

<script>
function esc(s){return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
async function loadPgDbs(){
  const r=await fetch('/api/pg/databases');const j=await r.json();
  if(j.error){document.getElementById('pgdb').innerHTML='<option>'+esc(j.error)+'</option>';return;}
  const sel=document.getElementById('pgdb');const cur=sel.value;
  sel.innerHTML=j.rows.map(x=>'<option value="'+esc(x[0])+'">'+esc(x[0])+' ('+esc(x[1])+')</option>').join('');
  if(cur&&[...sel.options].some(o=>o.value===cur))sel.value=cur;
}
async function loadPgInfo(){
  const db=document.getElementById('pgdb').value;if(!db)return;
  const r=await fetch('/api/pg/info?db='+encodeURIComponent(db));const j=await r.json();
  let v='';try{v=JSON.parse(j.version).rows[0][0].split(' on ')[0];}catch(e){}
  let exts='';try{exts=JSON.parse(j.extensions).rows.map(x=>x[0]+' '+x[1]).join(', ');}catch(e){}
  document.getElementById('pginfo').textContent=v+(exts?' | ext: '+exts:'');
}
async function loadPgTables(){
  const db=document.getElementById('pgdb').value;if(!db)return;
  const r=await fetch('/api/pg/tables?db='+encodeURIComponent(db));const j=await r.json();
  if(j.error){document.getElementById('pgtables').innerHTML='<tr><td colspan="4">'+esc(j.error)+'</td></tr>';return;}
  document.getElementById('pgtables').innerHTML=j.rows.map(x=>
    '<tr><td>'+esc(x[0])+'</td><td><a href="#" style="color:#4da3ff" onclick="browseTable(\''+esc(x[0])+'\',\''+esc(x[1])+'\');return false">'+esc(x[1])+'</a></td><td>'+esc(x[2])+'</td><td>'+esc(x[3])+'</td></tr>'
  ).join('')||'<tr><td colspan="4">no tables</td></tr>';
}
function browseTable(schema,tbl){
  document.getElementById('pgsq1').value='SELECT * FROM "'+schema+'"."'+tbl+'" LIMIT 100';
  runPgQuery();
}
async function runPgQuery(){
  const db=document.getElementById('pgdb').value;
  const sql=document.getElementById('pgsq1').value;
  document.getElementById('pgmsg').textContent='running…';
  const r=await fetch('/api/pg/query',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({db:db,sql:sql})});
  const j=await r.json();
  if(j.error){document.getElementById('pgmsg').textContent='';document.getElementById('pgresults').innerHTML='<tr><td style="color:#ff8d7d">'+esc(j.error)+'</td></tr>';return;}
  document.getElementById('pgmsg').textContent=j.rowcount+' row(s)';
  let h='<tr>'+j.columns.map(c=>'<th>'+esc(c)+'</th>').join('')+'</tr>';
  h+=j.rows.map(row=>'<tr>'+row.map(c=>'<td>'+esc(c)+'</td>').join('')+'</tr>').join('');
  document.getElementById('pgresults').innerHTML=h||'<tr><td>done</td></tr>';
}
async function runPsql(){
  const db=document.getElementById('pgdb').value;
  const cmd=document.getElementById('psqlin').value;
  if(!cmd.trim())return;
  const out=document.getElementById('psqlout');
  out.innerHTML+='<div style="color:#4da3ff">'+esc(db)+'# '+esc(cmd)+'</div>';
  document.getElementById('psqlin').value='';
  out.innerHTML+='<div style="color:#888">…</div>';
  out.scrollTop=out.scrollHeight;
  const r=await fetch('/api/pg/psql',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({db:db,cmd:cmd})});
  const j=await r.json();
  // replace the … placeholder with real output
  out.lastChild.remove();
  const txt=j.error?'ERROR: '+j.error:(j.output||'(no output)');
  const col=j.error?'#ff8d7d':'#c8e6c9';
  out.innerHTML+='<div style="color:'+col+'">'+esc(txt)+'</div>';
  out.scrollTop=out.scrollHeight;
}
async function loadPgAll(){await loadPgDbs();await loadPgInfo();await loadPgTables();}
loadPgAll();
setInterval(loadPgDbs,30000); // pick up newly created databases
document.getElementById('psqlin').addEventListener('keydown',e=>{if(e.key==='Enter')runPsql();});
</script></body></html>
'@

# --- Concurrent request handling (Kit 2026-10-13: allowed HTTP = 12) ---
# The old loop was strictly serial: one request (including slow wsl.exe
# calls) blocked every other request, so probes timed out and only one
# user could use the dashboard at a time. Requests are now dispatched to
# a runspace pool capped at 12 concurrent handlers.
$maxConcurrent = 12

$handler = {
    param($ctx)
    $req = $ctx.Request; $res = $ctx.Response
    $path = $req.Url.LocalPath
    try {
        if ($path -eq '/' -and $req.HttpMethod -eq 'GET') {
            $buf = [Text.Encoding]::UTF8.GetBytes($dashboardHtml)
            $res.ContentType = 'text/html; charset=utf-8'
            $res.OutputStream.Write($buf, 0, $buf.Length)
        }
        elseif ($path -eq '/api/ipconfig' -and $req.HttpMethod -eq 'GET') {
            $json = (Get-IpConfig) | ConvertTo-Json
            $buf = [Text.Encoding]::UTF8.GetBytes($json)
            $res.ContentType = 'application/json'
            $res.OutputStream.Write($buf, 0, $buf.Length)
        }
        elseif ($path -eq '/api/services' -and $req.HttpMethod -eq 'GET') {
            $list = foreach ($s in $services) {
                @{ name = $s.name; label = $s.label; status = (Get-ServiceStatus $s) }
            }
            $json = ($list | ConvertTo-Json)
            $buf = [Text.Encoding]::UTF8.GetBytes($json)
            $res.ContentType = 'application/json'
            $res.OutputStream.Write($buf, 0, $buf.Length)
        }
        elseif ($path -match '^/api/service/([^/]+)/(start|stop)$' -and $req.HttpMethod -eq 'POST') {
            $svc = $services | Where-Object { $_.name -eq $Matches[1] } | Select-Object -First 1
            if ($svc) {
                if ($Matches[2] -eq 'start') { $out = Start-ServiceLampy $svc } else { $out = Stop-ServiceLampy $svc }
                $json = (@{ result = "$($Matches[2]) $($svc.name): $out" } | ConvertTo-Json)
            } else {
                $res.StatusCode = 404
                $json = (@{ error = "unknown service" } | ConvertTo-Json)
            }
            $buf = [Text.Encoding]::UTF8.GetBytes($json)
            $res.ContentType = 'application/json'
            $res.OutputStream.Write($buf, 0, $buf.Length)
        }
        elseif ($path -eq '/api/pg/databases' -and $req.HttpMethod -eq 'GET') {
            $buf = [Text.Encoding]::UTF8.GetBytes(
                (Invoke-PgQuery 'postgres' 'SELECT datname AS database, pg_size_pretty(pg_database_size(datname)) AS size FROM pg_database WHERE datistemplate = false ORDER BY 1'))
            $res.ContentType = 'application/json'
            $res.OutputStream.Write($buf, 0, $buf.Length)
        }
        elseif ($path -eq '/api/pg/info' -and $req.HttpMethod -eq 'GET') {
            $db = $req.QueryString['db']; if (-not $db) { $db = 'postgres' }
            $ver = Invoke-PgQuery $db 'SELECT version() AS version'
            $ext = Invoke-PgQuery $db 'SELECT extname AS extension, extversion AS version FROM pg_extension ORDER BY 1'
            $json = (@{ version = $ver; extensions = $ext } | ConvertTo-Json -Depth 5)
            $buf = [Text.Encoding]::UTF8.GetBytes($json)
            $res.ContentType = 'application/json'
            $res.OutputStream.Write($buf, 0, $buf.Length)
        }
        elseif ($path -eq '/api/pg/tables' -and $req.HttpMethod -eq 'GET') {
            $db = $req.QueryString['db']; if (-not $db) { $db = 'postgres' }
            $buf = [Text.Encoding]::UTF8.GetBytes(
                (Invoke-PgQuery $db "SELECT n.nspname AS schema, c.relname AS tbl, pg_size_pretty(pg_total_relation_size(c.oid)) AS size, c.reltuples::bigint AS est_rows FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r','p') AND n.nspname NOT IN ('pg_catalog','information_schema') ORDER BY 1,2"))
            $res.ContentType = 'application/json'
            $res.OutputStream.Write($buf, 0, $buf.Length)
        }
        elseif ($path -eq '/api/pg/query' -and $req.HttpMethod -eq 'POST') {
            $reader = New-Object System.IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
            $params = ($reader.ReadToEnd() | ConvertFrom-Json)
            $reader.Close()
            $buf = [Text.Encoding]::UTF8.GetBytes((Invoke-PgQuery $params.db $params.sql))
            $res.ContentType = 'application/json'
            $res.OutputStream.Write($buf, 0, $buf.Length)
        }
        elseif ($path -eq '/api/pg/psql' -and $req.HttpMethod -eq 'POST') {
            $reader = New-Object System.IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
            $params = ($reader.ReadToEnd() | ConvertFrom-Json)
            $reader.Close()
            $buf = [Text.Encoding]::UTF8.GetBytes((Invoke-Psql $params.db $params.cmd))
            $res.ContentType = 'application/json'
            $res.OutputStream.Write($buf, 0, $buf.Length)
        }
        else { $res.StatusCode = 404 }
    } catch {
        $res.StatusCode = 500
        $buf = [Text.Encoding]::UTF8.GetBytes("error: $($_.Exception.Message)")
        try { $res.OutputStream.Write($buf, 0, $buf.Length) } catch {}
    }
    $res.Close()
}

# Pool runspaces need the helper functions and shared state in their
# initial session state (they do not inherit this script's scope).
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
foreach ($fn in 'Invoke-Distro','Get-SupervisorStatus','Get-PostgresStatus',
                'Get-ServiceStatus','Start-ServiceLampy','Stop-ServiceLampy',
                'Invoke-PgQuery','Invoke-Psql','Get-IpConfig') {
    $iss.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new(
        $fn, (Get-Command $fn).Definition))
}
$iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('services', $services, $null))
$iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('distro', $distro, $null))
$iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('dashboardHtml', $dashboardHtml, $null))
$pool = [runspacefactory]::CreateRunspacePool(1, $maxConcurrent, $iss, $Host)
$pool.Open()

$jobs = [System.Collections.ArrayList]::new()
try {
    # Async accept loop in 200ms slices: GetContext() blocks forever and swallows
    # Ctrl+C, but WaitOne(200) lets the stop request through promptly.
    $ar = $listener.BeginGetContext($null, $null)
    while ($true) {
        # Reap finished request jobs
        for ($i = $jobs.Count - 1; $i -ge 0; $i--) {
            if ($jobs[$i].Handle.IsCompleted) {
                try { $jobs[$i].PS.EndInvoke($jobs[$i].Handle) } catch {}
                $jobs[$i].PS.Dispose()
                $jobs.RemoveAt($i)
            }
        }
        if (-not $ar.AsyncWaitHandle.WaitOne(200)) { continue }
        try { $ctx = $listener.EndGetContext($ar) }
        catch { break }  # listener was stopped
        $ar = $listener.BeginGetContext($null, $null)
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($handler).AddArgument($ctx)
        $handle = $ps.BeginInvoke()
        [void]$jobs.Add(@{ PS = $ps; Handle = $handle })
    }
} finally {
    if ($listener.IsListening) { $listener.Stop() }
    $pool.Close(); $pool.Dispose()
}
