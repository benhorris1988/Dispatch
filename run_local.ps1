# Serve the API + web build locally without touching Apache config.
#   powershell -ExecutionPolicy Bypass -File run_local.ps1        # http://localhost:8090
# API:  http://localhost:8090/api/<endpoint>.php
# Web:  http://localhost:8090/mobile/build/web/
#       (after: cd mobile; flutter build web --release --base-href=/mobile/build/web/ --dart-define=API_BASE=http://localhost:8090/api)
param([int]$Port = 8090)
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
& 'C:\xampp\php\php.exe' -S "localhost:$Port" -t $root "$root\router.php"
