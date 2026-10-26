<?php
// Fixed actions of the GPU Unlock settings page. Unraid's local_prepend.php
// rejects any POST without the session csrf_token before this file runs.
$plugin = '/boot/config/plugins/gpu-unlock';
$ctl = '/usr/local/sbin/gpu-unlock-control';
$back = '/Settings/GPUUnlock';
$action = $_POST['action'] ?? $_GET['action'] ?? '';

if ($action === 'log') {
  header('Content-Type: text/plain; charset=utf-8');
  header('Content-Disposition: attachment; filename="gpu-unlock-'.date('Ymd-His').'.log"');
  echo shell_exec("$ctl status"), "\n", shell_exec("$ctl inspect"), "\n";
  @readfile('/var/log/gpu-unlock.log');
  exit;
}
if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
  http_response_code(405);
  exit;
}

$out = [];
if ($action === 'save') {
  // Only full PCI addresses of supported cards present now are kept.
  $supported = [];
  exec("$ctl inspect", $lines);
  foreach ($lines as $line) {
    $f = explode("\t", $line);
    if ($f[0] === 'gpu' && $f[3] === 'yes') $supported[] = $f[1];
  }
  $targets = array_values(array_intersect($supported, (array)($_POST['targets'] ?? [])));
  $enabled = ($_POST['enabled'] ?? '') === 'yes' && $targets ? 'yes' : 'no';
  @mkdir($plugin, 0777, true);
  if (file_put_contents("$plugin/settings.cfg", "enabled=\"$enabled\"\ntargets=\"".implode(',', $targets)."\"\n") === false) {
    $out[] = '无法写入 settings.cfg，配置未保存。';
  } else {
    exec("$ctl prepare-boot 2>&1", $out, $rc);
    if ($rc !== 0) {
      exec("$ctl disable");
      $out[] = '未启用。';
    }
  }
} elseif ($action === 'disable') {
  exec("$ctl disable 2>&1", $out);
}
header("Location: $back?msg=".rawurlencode(implode(' ', $out)));
