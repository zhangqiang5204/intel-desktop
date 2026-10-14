"""Pure injected capture-connection recovery cases; macOS/Xcode, no live capture or input."""
from pathlib import Path
import subprocess,json,tempfile
root=Path(__file__).resolve().parents[1];source=(root/'native/NativeWindowCapture.swift').read_text()
function=source[source.index('func visualCaptureConnectionRecovery<T>'):source.index('// Each request owns')]
body=r'''
import Foundation
import ScreenCaptureKit
struct HelperError: Error { let details: [String: Any] }
'''+function+r'''
var count = 0
var checks = 0
let failure = HelperError(details:["capture_error_domain":SCStreamErrorDomain,"capture_error_code":-3805,"capture_stage":"starting_app_filter"])
func assertTest(_ value: Bool) { if !value { exit(1) } }
let recovered = try visualCaptureConnectionRecovery(deadline:20,now:{10},check:{checks += 1}) { () throws -> Int in
 count += 1;if count == 1 {throw failure};return 42
}
assertTest(recovered.0 == 42 && recovered.1 && count == 2 && checks == 1)
for details in [ ["capture_error_domain":SCStreamErrorDomain,"capture_error_code":-3801,"capture_stage":"starting_app_filter"],
                 ["capture_error_domain":SCStreamErrorDomain,"capture_error_code":-3805,"capture_stage":"awaiting_postupdate_complete"],
                 ["capture_error_domain":"other","capture_error_code":-3805,"capture_stage":"starting_app_filter"] ] {
 count = 0
 do { _ = try visualCaptureConnectionRecovery(deadline:20,now:{10},check:{}) { () throws -> Int in count += 1;throw HelperError(details:details) };exit(1) }
 catch { assertTest(count == 1) }
}
count = 0
 do { _ = try visualCaptureConnectionRecovery(deadline:10,now:{10},check:{}) { () throws -> Int in count += 1;throw failure };exit(1) }
 catch { assertTest(count == 1) }
count = 0
 do { _ = try visualCaptureConnectionRecovery(deadline:20,now:{10},check:{throw HelperError(details:[:])}) { () throws -> Int in count += 1;throw failure };exit(1) }
 catch { assertTest(count == 1) }
count = 0
 do { _ = try visualCaptureConnectionRecovery(deadline:20,now:{10},check:{}) { () throws -> Int in count += 1;throw failure };exit(1) }
 catch { assertTest(count == 2) }
print("{\"ok\":true,\"cases\":7,\"capture_performed\":false,\"input_performed\":false}")
'''
with tempfile.TemporaryDirectory(prefix='intel-desktop-capture-test-') as directory:
 p=Path(directory)/'recovery-self-test.swift';p.write_text(body)
 result=subprocess.run(['xcrun','swift',str(p)],capture_output=True,text=True,timeout=40)
 if result.returncode:
  print(result.stderr[:2000]);raise SystemExit(result.returncode)
 print(json.dumps(json.loads(result.stdout)))
