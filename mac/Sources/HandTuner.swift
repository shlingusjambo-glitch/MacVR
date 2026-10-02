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
        var bones: [String: [Float]] = [:]
        for (n, m) in HandTuner.names { bones[n] = (HandModel.boneOffsets[m] ?? Array(repeating: 0, count: 15)).map { $0 * 180 / .pi } }
        return ["placements": out, "bones": bones, "look": HandModel.look, "current": HandTuner.names.first { $0.1 == model() }?.0 ?? "quest2", "pose": pose]
    }

    private func respond(_ c: NWConnection, _ r: Req) {
        switch (r.method, r.path) {
        case ("GET", "/"): send(c, "200 OK", "text/html; charset=utf-8", Data(HandTuner.page.utf8))
        case ("GET", "/state"): json(c, state())
        case ("POST", "/place"):
            guard let o = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any], let n = o["model"] as? String,
                  let m = HandTuner.names.first(where: { $0.0 == n })?.1 else { send(c, "400 Bad Request", "text/plain", Data()); return }
            if let p = (o["pos"] as? [NSNumber])?.map(\.floatValue), let q = (o["rot"] as? [NSNumber])?.map(\.floatValue), p.count == 3, q.count == 4 {
                HandModel.place[m] = (SIMD3(p[0], p[1], p[2]), simd_normalize(simd_quatf(vector: SIMD4(q[0], q[1], q[2], q[3]))))   // metres + quaternion (3D page)
            } else if let v = (o["v"] as? [NSNumber])?.map(\.floatValue), v.count == 6 {
                let d = Float.pi / 180
                HandModel.place[m] = (SIMD3(v[0], v[1], v[2]) / 1000,
                                      simd_quatf(angle: v[3] * d, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: v[4] * d, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: v[5] * d, axis: SIMD3(0, 0, 1)))
            } else { send(c, "400 Bad Request", "text/plain", Data()); return }
            rebuild(); json(c, ["ok": true])
        case ("GET", "/controller.glb"):   // the left controller mesh the hand holds (grip space)
            let n = r.query["model"] ?? "quest1", m = HandTuner.names.first { $0.0 == n }?.1 ?? .quest1
            let profile = ["oculus-touch-v2", "oculus-touch-v3", "meta-quest-touch-plus"][m.controllerMesh.rawValue]
            if let u = Bundle.main.resourceURL?.appendingPathComponent("controllers/\(profile)/left.glb"), let d = try? Data(contentsOf: u) {
                send(c, "200 OK", "model/gltf-binary", d) } else { send(c, "404 Not Found", "text/plain", Data()) }
        case ("GET", "/mesh"):   // the posed left hand in its own (mesh) space + its placement, for the 3D page
            let n = r.query["model"] ?? "quest1", m = HandTuner.names.first { $0.0 == n }?.1 ?? .quest1
            let out = DispatchQueue.main.sync { () -> [String: Any]? in
                let ctl = ControllerModels.build(m, hand: 0), rig = ControllerRig(ctl, hand: 0)
                guard let hm = HandModel(hand: 0, model: m, controller: ctl), let pl = HandModel.place[m] else { return nil }
                let input = Compositor.demoInput(pose == "live" ? "idle" : pose, hand: 0)
                rig.update(input); hm.update(input, targets: rig.targets(), poke: pose == "poke")
                guard let g = hm.node.geometry, let vs = g.sources(for: .vertex).first, let el = g.elements.first else { return nil }
                let verts: [Float] = vs.data.withUnsafeBytes { raw in (0..<vs.vectorCount * 3).map { i in
                    raw.loadUnaligned(fromByteOffset: vs.dataOffset + (i / 3) * vs.dataStride + (i % 3) * vs.bytesPerComponent, as: Float.self) } }
                let idx: [Int] = el.data.withUnsafeBytes { raw in (0..<el.primitiveCount * 3).map { i in
                    el.bytesPerIndex == 4 ? Int(raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)) : Int(raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)) } }
                let q = pl.rot.vector
                return ["pos": [pl.pos.x, pl.pos.y, pl.pos.z], "rot": [q.x, q.y, q.z, q.w], "verts": verts, "idx": idx]
            }
            if let out { json(c, out) } else { send(c, "500 Internal Server Error", "text/plain", Data()) }
        case ("POST", "/bones"):   // manual joint tweaks, degrees, 15 per controller
            guard let o = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any], let n = o["model"] as? String,
                  let m = HandTuner.names.first(where: { $0.0 == n })?.1, let v = (o["v"] as? [NSNumber])?.map(\.floatValue), v.count == 15 else {
                send(c, "400 Bad Request", "text/plain", Data()); return }
            HandModel.boneOffsets[m] = v.map { $0 * .pi / 180 }
            rebuild(); json(c, ["ok": true])
        case ("POST", "/look"):   // fill RGB, edge RGB, fill opacity, edge opacity, edge width
            guard let o = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any], let v = (o["v"] as? [NSNumber])?.map(\.floatValue),
                  v.count == HandModel.look.count else { send(c, "400 Bad Request", "text/plain", Data()); return }
            HandModel.look = v
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
:root{--bg:#1c272e;--panel:#243039ee;--line:#34404a;--text:#e0e5e8;--dim:#a4adb4;--blue:#2a73f5}
@media (prefers-color-scheme: light){:root:not([data-theme="dark"]){--bg:#dfe5e9;--panel:#ffffffee;--line:#d5dbe0;--text:#1c272e;--dim:#5d6a75}}
html,body{margin:0;height:100%;background:var(--bg);color:var(--text);font:14px -apple-system,system-ui,sans-serif;overflow:hidden}
#view{position:fixed;inset:0}
aside{position:fixed;top:12px;left:12px;width:300px;max-height:calc(100% - 24px);overflow:auto;background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:14px;box-sizing:border-box}
@media (max-width:640px){aside{left:8px;right:8px;width:auto;top:auto;bottom:8px;max-height:45%}}
h1{font-size:16px;margin:0 0 4px} p{color:var(--dim);margin:0 0 10px;line-height:1.35;font-size:13px}
h2{font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:var(--dim);margin:14px 0 6px;font-weight:600}
.row{display:flex;flex-wrap:wrap;gap:6px;align-items:center}
button{background:var(--line);color:var(--text);border:0;border-radius:999px;padding:6px 11px;font:inherit;cursor:pointer}
button.on,button.primary{background:var(--blue);color:#fff}
input[type=number]{width:56px;background:transparent;color:var(--text);border:1px solid var(--line);border-radius:6px;padding:3px 5px;font:inherit}
#msg{color:var(--dim);font-size:12px;margin-top:8px;min-height:16px}
kbd{border:1px solid var(--line);border-radius:4px;padding:0 4px;font-size:11px}
.sl{display:grid;grid-template-columns:96px 1fr 40px;gap:8px;align-items:center;color:var(--dim);margin:6px 0}
.sl output{font-variant-numeric:tabular-nums;text-align:right}
input[type=color]{width:34px;height:24px;border:0;background:none;padding:0;vertical-align:middle}
</style>
<script type="importmap">{"imports":{"three":"https://cdn.jsdelivr.net/npm/three@0.160.0/build/three.module.js","three/addons/":"https://cdn.jsdelivr.net/npm/three@0.160.0/examples/jsm/"}}</script>
</head><body><div id="view"></div>
<aside>
<h1>Hand Tuner</h1>
<p>Drag the arrows to move the left hand, the rings to turn it. The right hand mirrors it. Fingers re-wrap after each change, live in the headset too. Orbit: drag. Pan: right-drag. Zoom: scroll.</p>
<h2>Controller</h2><div class="row" id="models"></div>
<h2>View</h2><div class="row" id="views"></div>
<h2>Gizmo</h2>
<div class="row"><button id="mT" class="on">Move <kbd>W</kbd></button><button id="mR">Rotate <kbd>E</kbd></button></div>
<div class="row" style="margin-top:6px"><button id="sm" class="on">Smooth</button><button id="sn">Snap</button>
<label>Step <input id="stepT" type="number" value="1" min="0.1" step="0.5"> mm</label><label><input id="stepR" type="number" value="5" min="1" step="1"> °</label></div>
<p>Hold the controllers the way you normally do and move these until the drawn controllers sit where your real ones are.</p>
<h2>Fingers (adds to the automatic pose)</h2>
<div class="row" id="fingers"></div><div id="joints"></div>
<h2>Material</h2>
<div class="row"><label>Fill <input id="fillC" type="color"></label><label>Edge <input id="edgeC" type="color"></label></div>
<label class="sl">Fill opacity <input id="fillA" type="range" min="0" max="1" step="0.01"></label>
<label class="sl">Edge opacity <input id="edgeA" type="range" min="0" max="1" step="0.01"></label>
<label class="sl">Edge width <input id="edgeW" type="range" min="0.05" max="1" step="0.01"></label>
<h2>Play a pose</h2><div class="row" id="poses"></div>
<h2>Placement</h2><div class="row"><button class="primary" id="save">Save</button><button id="reset">Forget saved</button></div>
<div id="msg"></div>
</aside>
<script type="module">
import * as THREE from "three";
import {OrbitControls} from "three/addons/controls/OrbitControls.js";
import {TransformControls} from "three/addons/controls/TransformControls.js";
import {GLTFLoader} from "three/addons/loaders/GLTFLoader.js";
const $=s=>document.querySelector(s);
const poses=[["live","Live"],["idle","Idle"],["index_touch","On trigger"],["trigger_pull","Pull trigger"],["thumbrest","Thumb rest"],["stick","On stick"],["stick_circle","Move stick"],["face_low","X / A"],["face_high","Y / B"],["grip","Squeeze"],["poke","Point"],["cycle","Play all"]];
const animated=new Set(["trigger_pull","stick_circle","grip","cycle"]);
let model="quest1",pose="live",snap=false;
const view=$("#view"),renderer=new THREE.WebGLRenderer({antialias:true,alpha:true});
renderer.setPixelRatio(devicePixelRatio);view.appendChild(renderer.domElement);
const scene=new THREE.Scene(),camera=new THREE.PerspectiveCamera(35,1,0.005,10);
camera.position.set(-0.28,0.16,0.24);
scene.add(new THREE.HemisphereLight(0xffffff,0x445566,2.2));const key=new THREE.DirectionalLight(0xffffff,2);key.position.set(-1,2,1);scene.add(key);
const grid=new THREE.GridHelper(0.4,40,0x667788,0x334455);grid.position.y=-0.12;scene.add(grid);
const orbit=new OrbitControls(camera,renderer.domElement);orbit.target.set(0,0,0.01);orbit.enableDamping=true;
const ctlL=new THREE.Group(),ctlR=new THREE.Group();scene.add(ctlL,ctlR);ctlR.scale.x=-1;ctlR.position.x=0.16;ctlL.position.x=0;
const handL=new THREE.Group(),handR=new THREE.Group();ctlL.add(handL);ctlR.add(handR);
const handMat=new THREE.MeshStandardMaterial({color:0x8d98a3,roughness:0.7,transparent:true,opacity:0.8,side:THREE.DoubleSide});
const handMesh=new THREE.Mesh(new THREE.BufferGeometry(),handMat),handMeshR=new THREE.Mesh(handMesh.geometry,handMat);
handL.add(handMesh);handR.add(handMeshR);
const gizmo=new TransformControls(camera,renderer.domElement);gizmo.setSize(0.8);gizmo.attach(handL);scene.add(gizmo);
gizmo.addEventListener("dragging-changed",e=>{orbit.enabled=!e.value;if(!e.value)push(true)});
gizmo.addEventListener("objectChange",()=>{handR.position.copy(handL.position);handR.quaternion.copy(handL.quaternion);push(false)});
const loader=new GLTFLoader();
function loadController(){[ctlL,ctlR].forEach(g=>g.children.filter(c=>c.userData.ctl).forEach(c=>g.remove(c)));
 loader.load(`/controller.glb?model=${model}`,gl=>{[ctlL,ctlR].forEach((g,i)=>{const o=i?gl.scene.clone():gl.scene;o.userData.ctl=true;g.add(o)})})}
let inflight=false,pending=false,last=0;
async function loadMesh(applyPlacement){
 const m=await (await fetch(`/mesh?model=${model}`)).json();
 const g=new THREE.BufferGeometry();g.setAttribute("position",new THREE.Float32BufferAttribute(m.verts,3));g.setIndex(m.idx);g.computeVertexNormals();
 handMesh.geometry.dispose();handMesh.geometry=g;handMeshR.geometry=g;
 if(applyPlacement){handL.position.fromArray(m.pos);handL.quaternion.set(m.rot[0],m.rot[1],m.rot[2],m.rot[3]);handR.position.copy(handL.position);handR.quaternion.copy(handL.quaternion)}
}
async function push(final){
 if(inflight){pending=true;return}
 const now=performance.now();if(!final&&now-last<90){pending=true;setTimeout(()=>{if(pending){pending=false;push(false)}},90);return}
 inflight=true;last=now;
 const q=handL.quaternion;
 await fetch("/place",{method:"POST",body:JSON.stringify({model,pos:handL.position.toArray(),rot:[q.x,q.y,q.z,q.w]})});
 await loadMesh(false);inflight=false;
 if(pending){pending=false;push(final)}
}
function setSnap(on){snap=on;$("#sn").classList.toggle("on",on);$("#sm").classList.toggle("on",!on);
 gizmo.setTranslationSnap(on?(+$("#stepT").value||1)/1000:null);gizmo.setRotationSnap(on?THREE.MathUtils.degToRad(+$("#stepR").value||5):null)}
$("#sm").onclick=()=>setSnap(false);$("#sn").onclick=()=>setSnap(true);$("#stepT").onchange=$("#stepR").onchange=()=>setSnap(snap);
function setMode(m){gizmo.setMode(m);$("#mT").classList.toggle("on",m=="translate");$("#mR").classList.toggle("on",m=="rotate")}
$("#mT").onclick=()=>setMode("translate");$("#mR").onclick=()=>setMode("rotate");
addEventListener("keydown",e=>{if(e.target.tagName=="INPUT")return;if(e.key=="w")setMode("translate");if(e.key=="e")setMode("rotate")});
function drawModels(){$("#models").innerHTML=[["quest1","Quest 1"],["quest2","Quest 2"],["quest3","Quest 3 / Frame"]].map(([m,l])=>`<button class="${m==model?"on":""}" data-m="${m}">${l}</button>`).join("");
 document.querySelectorAll("[data-m]").forEach(b=>b.onclick=()=>{model=b.dataset.m;drawModels();drawFingers();loadController();loadMesh(true)})}
function drawPoses(){$("#poses").innerHTML=poses.map(([p,l])=>`<button class="${p==pose?"on":""}" data-p="${p}">${l}</button>`).join("");
 document.querySelectorAll("[data-p]").forEach(b=>b.onclick=async()=>{pose=b.dataset.p;await fetch("/pose?name="+pose,{method:"POST"});drawPoses();loadMesh(false)})}
const fingerNames=["Pinky","Ring","Middle","Index","Thumb"],jointNames=["Knuckle","Middle","Tip"];
let finger=2,bones=null,look=null,boneTimer=null,lookTimer=null;
function drawFingers(){$("#fingers").innerHTML=fingerNames.map((n,i)=>`<button class="${i==finger?"on":""}" data-f="${i}">${n}</button>`).join("");
 document.querySelectorAll("[data-f]").forEach(b=>b.onclick=()=>{finger=+b.dataset.f;drawFingers()});
 const v=bones[model];
 $("#joints").innerHTML=jointNames.map((n,k)=>`<label class="sl">${n}<input type="range" min="-90" max="90" step="1" value="${v[finger*3+k]}" data-j="${finger*3+k}"><output>${Math.round(v[finger*3+k])}°</output></label>`).join("");
 document.querySelectorAll("[data-j]").forEach(r=>r.oninput=()=>{bones[model][+r.dataset.j]=+r.value;r.nextElementSibling.textContent=r.value+"°";
  clearTimeout(boneTimer);boneTimer=setTimeout(async()=>{await fetch("/bones",{method:"POST",body:JSON.stringify({model,v:bones[model]})});loadMesh(false)},80)})}
const hex=a=>"#"+a.map(x=>Math.round(x*255).toString(16).padStart(2,"0")).join(""),rgb=h=>[1,3,5].map(i=>parseInt(h.slice(i,i+2),16)/255);
function drawLook(){$("#fillC").value=hex(look.slice(0,3));$("#edgeC").value=hex(look.slice(3,6));$("#fillA").value=look[6];$("#edgeA").value=look[7];$("#edgeW").value=look[8];
 handMat.color.setRGB(look[0]*1.6+0.15,look[1]*1.6+0.15,look[2]*1.6+0.15);handMat.opacity=Math.max(0.15,look[6])}
["fillC","edgeC","fillA","edgeA","edgeW"].forEach(id=>$("#"+id).oninput=()=>{look=[...rgb($("#fillC").value),...rgb($("#edgeC").value),+$("#fillA").value,+$("#edgeA").value,+$("#edgeW").value];drawLook();
 clearTimeout(lookTimer);lookTimer=setTimeout(()=>fetch("/look",{method:"POST",body:JSON.stringify({v:look})}),120)});
setInterval(()=>{if(animated.has(pose)&&!inflight)loadMesh(false)},120);
$("#save").onclick=async()=>{const r=await (await fetch("/save",{method:"POST"})).json();$("#msg").textContent="Saved to "+r.path};
$("#reset").onclick=async()=>{const r=await (await fetch("/reset",{method:"POST"})).json();$("#msg").textContent=r.note};
const camViews={Outside:[-0.45,0.08,0.05],Inside:[0.45,0.08,0.05],Front:[0,0.1,-0.45],Back:[0,0.12,0.45],Top:[0.001,0.45,0.02],Under:[0.001,-0.45,0.05]};
$("#views").innerHTML=Object.keys(camViews).map(k=>`<button data-v="${k}">${k}</button>`).join("");
document.querySelectorAll("[data-v]").forEach(b=>b.onclick=()=>{camera.position.fromArray(camViews[b.dataset.v]);orbit.target.set(0,0,0.01);orbit.update()});
function resize(){const w=view.clientWidth,h=view.clientHeight;renderer.setSize(w,h);camera.aspect=w/h;camera.updateProjectionMatrix()}
addEventListener("resize",resize);resize();
renderer.setAnimationLoop(()=>{orbit.update();renderer.render(scene,camera)});
const st=await (await fetch("/state")).json();model=st.current;pose=st.pose;bones=st.bones;look=st.look;drawModels();drawPoses();drawFingers();drawLook();loadController();loadMesh(true);
</script></body></html>
"""
}
