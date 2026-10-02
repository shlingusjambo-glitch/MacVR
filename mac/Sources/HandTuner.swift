import Foundation
import Network
import SceneKit
import AppKit

/// Temporary hand tuner: a small web page on http://127.0.0.1:8770 to place the in-home hands on each controller
/// (position + rotation), play poses on them (live in the headset and as a preview here), and save the placement.
/// Saved placements go to Application Support/VR4Mac/hand-placement.json and load on every launch.
final class HandTuner {
    private var listener: NWListener?
    private let q = DispatchQueue(label: "vr4.handtuner")
    /// Engine hooks: rebuild the live hands, set the played pose (nil = live input), current controller mesh.
    var rebuild: () -> Void = {}
    var setPose: (String?) -> Void = { _ in }
    var model: () -> HeadsetModel = { .quest2 }
    private var pose = "live"

    func start() {
        let params = NWParameters.tcp   // loopback only: never reachable from the LAN
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 8770)
        guard let l = try? NWListener(using: params) else { NSLog("VR4Mac: hand tuner port busy"); return }
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.start(queue: q); listener = l
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: q)
        var buf = Data()
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] d, _, done, err in
                guard let self else { return }
                if let d { buf.append(d) }
                if let req = self.parse(buf) { self.respond(c, req) } else if !done && err == nil { read() } else { c.cancel() }
            }
        }
        read()
    }
    private struct Req { let method, path: String; let query: [String: String]; let body: Data }
    private func parse(_ d: Data) -> Req? {
        guard let end = d.range(of: Data("\r\n\r\n".utf8)), let head = String(data: d[..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n"), first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        let len = lines.compactMap { l -> Int? in l.lowercased().hasPrefix("content-length:") ? Int(l.dropFirst(15).trimmingCharacters(in: .whitespaces)) : nil }.first ?? 0
        let body = d[end.upperBound...]
        guard body.count >= len else { return nil }
        let comps = URLComponents(string: String(first[1]))
        var query: [String: String] = [:]
        comps?.queryItems?.forEach { query[$0.name] = $0.value }
        return Req(method: String(first[0]), path: comps?.path ?? "/", query: query, body: Data(body.prefix(len)))
    }
    private func send(_ c: NWConnection, _ status: String, _ type: String, _ body: Data) {
        var h = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        h.append(body)
        c.send(content: h, completion: .contentProcessed { _ in c.cancel() })
    }
    private func json(_ c: NWConnection, _ o: Any) { send(c, "200 OK", "application/json", (try? JSONSerialization.data(withJSONObject: o)) ?? Data()) }

    private static let names: [(String, HeadsetModel)] = [("quest1", .quest1), ("quest2", .quest2), ("quest3", .quest3)]
    /// Placement as mm + degrees (rotation applied X, then Y, then Z) for the sliders.
    private func state() -> [String: Any] {
        var out: [String: Any] = [:]
        for (n, m) in HandTuner.names {
            guard let p = HandModel.place[m] else { continue }
            let r = simd_float3x3(p.rot)
            let y = asin(max(-1, min(1, r.columns.2.x))), x = atan2(-r.columns.2.y, r.columns.2.z), z = atan2(-r.columns.1.x, r.columns.0.x)
            out[n] = [p.pos.x * 1000, p.pos.y * 1000, p.pos.z * 1000, x * 180 / .pi, y * 180 / .pi, z * 180 / .pi]
        }
        return ["placements": out, "current": HandTuner.names.first { $0.1 == model() }?.0 ?? "quest2", "pose": pose]
    }

    private func respond(_ c: NWConnection, _ r: Req) {
        switch (r.method, r.path) {
        case ("GET", "/"): send(c, "200 OK", "text/html; charset=utf-8", Data(HandTuner.page.utf8))
        case ("GET", "/state"): json(c, state())
        case ("POST", "/place"):
            guard let o = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any], let n = o["model"] as? String,
                  let m = HandTuner.names.first(where: { $0.0 == n })?.1, let v = (o["v"] as? [NSNumber])?.map(\.floatValue), v.count == 6 else {
                send(c, "400 Bad Request", "text/plain", Data()); return }
            let d = Float.pi / 180
            HandModel.place[m] = (SIMD3(v[0], v[1], v[2]) / 1000,
                                  simd_quatf(angle: v[3] * d, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: v[4] * d, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: v[5] * d, axis: SIMD3(0, 0, 1)))
            rebuild(); json(c, ["ok": true])
        case ("POST", "/pose"):
            pose = r.query["name"] ?? "live"
            setPose(pose == "live" ? nil : pose); json(c, ["ok": true])
        case ("POST", "/save"):
            HandModel.save(); json(c, ["ok": true, "path": HandModel.savedURL.path])
        case ("POST", "/reset"):
            try? FileManager.default.removeItem(at: HandModel.savedURL)
            json(c, ["ok": true, "note": "Saved placement removed; restart MacVR to get the built-in placement back."])
        case ("GET", "/preview"):
            let n = r.query["model"] ?? "quest1", m = HandTuner.names.first { $0.0 == n }?.1 ?? .quest1
            let hand = r.query["hand"] == "right" ? 1 : 0
            let dirs: [String: SIMD3<Float>] = ["first": SIMD3(-0.25, 0.7, 0.7), "outside": SIMD3(-1, 0.15, 0.1), "inside": SIMD3(1, 0.15, 0.1),
                                              "front": SIMD3(0, 0.2, -1), "top": SIMD3(0, 1, 0.15), "bottom": SIMD3(0, -1, 0.2)]
            var dir = dirs[r.query["view"] ?? "first"] ?? dirs["first"]!
            if hand == 1 { dir.x = -dir.x }
            let png = DispatchQueue.main.sync { () -> Data? in
                let ctl = ControllerModels.build(m, hand: hand), rig = ControllerRig(ctl, hand: hand)
                guard let hm = HandModel(hand: hand, model: m, controller: ctl) else { return nil }
                let comp = Compositor.demoInput(pose, hand: hand)
                rig.update(comp); hm.update(comp, targets: rig.targets(), poke: pose == "poke"); hm.update(comp, targets: rig.targets(), poke: pose == "poke")
                let root = SCNNode(); root.addChildNode(ctl); root.addChildNode(hm.node)
                guard let img = ControllerPortrait.renderNode(root, size: 520, dir: dir, fill: 2.4) else { return nil }
                return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
            }
            if let png { send(c, "200 OK", "image/png", png) } else { send(c, "500 Internal Server Error", "text/plain", Data()) }
        default: send(c, "404 Not Found", "text/plain", Data())
        }
    }

    private static let page = """
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Hand Tuner</title>
<style>
:root{--bg:#1c272e;--panel:#243039;--line:#34404a;--text:#e0e5e8;--dim:#a4adb4;--blue:#2a73f5}
@media (prefers-color-scheme: light){:root:not([data-theme="dark"]){--bg:#eef1f3;--panel:#fff;--line:#d5dbe0;--text:#1c272e;--dim:#5d6a75}}
body{margin:0;background:var(--bg);color:var(--text);font:15px -apple-system,system-ui,sans-serif}
main{max-width:1180px;margin:0 auto;padding:20px 16px;display:grid;grid-template-columns:360px 1fr;gap:20px}
@media (max-width:820px){main{grid-template-columns:1fr}}
h1{font-size:20px;margin:0 0 4px} p{color:var(--dim);margin:0 0 14px;line-height:1.4}
.card{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:16px;margin-bottom:16px}
label{display:grid;grid-template-columns:90px 1fr 64px;align-items:center;gap:10px;margin:8px 0;color:var(--dim)}
input[type=range]{width:100%} input[type=number]{width:64px;background:var(--bg);color:var(--text);border:1px solid var(--line);border-radius:6px;padding:3px}
.row{display:flex;flex-wrap:wrap;gap:8px}
button{background:var(--line);color:var(--text);border:0;border-radius:999px;padding:8px 14px;font:inherit;cursor:pointer}
button.on,button.primary{background:var(--blue);color:#fff}
.views{display:grid;grid-template-columns:repeat(3,1fr);gap:10px}
.views figure{margin:0;background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden}
.views img{width:100%;display:block;aspect-ratio:1;background:#0003} figcaption{font-size:12px;color:var(--dim);padding:6px 10px}
#msg{color:var(--dim);font-size:13px;min-height:18px;margin-top:8px}
</style></head><body><main>
<section>
<h1>Hand Tuner</h1><p>Move the hand on the controller. It updates live in the headset and in the previews. Play a pose to check the fingers, then save.</p>
<div class="card"><div class="row" id="models"></div></div>
<div class="card" id="sliders"></div>
<div class="card"><div class="row" id="poses"></div></div>
<div class="card"><div class="row"><button class="primary" id="save">Save placement</button><button id="reset">Forget saved</button></div><div id="msg"></div></div>
</section>
<section><div class="row" style="margin-bottom:10px"><button id="lr" data-hand="left">Left hand</button></div><div class="views" id="views"></div></section>
</main><script>
const axes=[["Left / right","mm",-80,80],["Up / down","mm",-80,80],["Back / front","mm",-80,80],["Tilt","°",-180,180],["Turn","°",-180,180],["Roll","°",-180,180]];
const poses=[["live","Live input"],["idle","Idle"],["index_touch","Finger on trigger"],["trigger_pull","Pull trigger"],["thumbrest","Thumb rest"],["stick","Thumb on stick"],["stick_circle","Move stick"],["face_low","X / A"],["face_high","Y / B"],["grip","Squeeze grip"],["poke","Point"],["cycle","Play all"]];
const views=["first","outside","inside","front","top","bottom"];
let st=null,model="quest1",hand="left",timer=null,tick=0;
const $=s=>document.querySelector(s);
async function load(){st=await (await fetch("/state")).json();model=st.current;draw()}
function draw(){
 $("#models").innerHTML=["quest1","quest2","quest3"].map(m=>`<button class="${m==model?"on":""}" data-m="${m}">${{quest1:"Quest 1",quest2:"Quest 2",quest3:"Quest 3 / Frame"}[m]}</button>`).join("");
 document.querySelectorAll("[data-m]").forEach(b=>b.onclick=()=>{model=b.dataset.m;draw();refresh()});
 const v=st.placements[model];
 $("#sliders").innerHTML=axes.map((a,i)=>`<label>${a[0]}<input type="range" min="${a[2]}" max="${a[3]}" step="${a[1]=="mm"?0.5:1}" value="${v[i].toFixed(1)}" data-i="${i}"><input type="number" step="${a[1]=="mm"?0.5:1}" value="${v[i].toFixed(1)}" data-n="${i}"></label>`).join("");
 document.querySelectorAll("[data-i]").forEach(r=>r.oninput=()=>set(+r.dataset.i,+r.value));
 document.querySelectorAll("[data-n]").forEach(r=>r.onchange=()=>set(+r.dataset.n,+r.value));
 $("#poses").innerHTML=poses.map(p=>`<button class="${p[0]==st.pose?"on":""}" data-p="${p[0]}">${p[1]}</button>`).join("");
 document.querySelectorAll("[data-p]").forEach(b=>b.onclick=async()=>{await fetch("/pose?name="+b.dataset.p,{method:"POST"});st.pose=b.dataset.p;draw();refresh()});
 refresh();
}
function set(i,x){st.placements[model][i]=x;document.querySelector(`[data-i="${i}"]`).value=x;document.querySelector(`[data-n="${i}"]`).value=x;
 clearTimeout(timer);timer=setTimeout(async()=>{await fetch("/place",{method:"POST",body:JSON.stringify({model,v:st.placements[model]})});refresh()},60)}
function refresh(){tick++;$("#views").innerHTML=views.map(v=>`<figure><img src="/preview?model=${model}&hand=${hand}&view=${v}&t=${tick}" alt="${v} view"><figcaption>${v}</figcaption></figure>`).join("")}
$("#lr").onclick=()=>{hand=hand=="left"?"right":"left";$("#lr").textContent=hand=="left"?"Left hand":"Right hand";refresh()};
$("#save").onclick=async()=>{const r=await (await fetch("/save",{method:"POST"})).json();$("#msg").textContent="Saved to "+r.path};
$("#reset").onclick=async()=>{const r=await (await fetch("/reset",{method:"POST"})).json();$("#msg").textContent=r.note};
load();
</script></body></html>
"""
}
