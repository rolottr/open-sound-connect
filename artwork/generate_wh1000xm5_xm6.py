"""Original WH-1000XM5 and WH-1000XM6 studies, built in Blender.

Run headless from the repository root:
    Blender -b --factory-startup -P artwork/generate_wh1000xm5_xm6.py -- XM5 XM6

All geometry and materials are authored here; reference photographs are not bundled.
Both models share the XM4 study's coordinate frame, studio, camera and export settings
(x: wearer's right, y: wearer's front, z: up), so the app frames them identically.
Pass `preview DIR` after the model names to render comparison views instead of exporting.
"""
import bpy
import bmesh
import math
import sys
from bisect import bisect_left
from mathutils import Matrix, Vector
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'Resources/Models'
XM4_HEIGHT = .2195  # bounding-box height of artwork/WH-1000XM4.blend

# Earcup silhouette traced from a side-on product photograph of the XM5 (polar radius about the
# cup's bounding-box centre in half-width units, 7-harmonic Fourier fit, 18 degree tilt removed).
# The XM6 shares the egg-shaped cup, a touch wider.
CUP_OUTLINE = [1.1115, -0.0017, 0.0308, -0.1363, 0.0628, -0.0038, -0.0037, -0.0029, 0.0101,
               -0.001, -0.001, 0.001, 0.0018, -0.0001, 0.0004]

SPECS = {
    'XM5': dict(
        name='WH-1000XM5',
        cup=dict(a=.0392, widen=1.0, tilt=24, cx=.050, zc=.050, wall=.0088, cap=.0186, cap_power=3.0),
        touch=dict(center=(-.0008, .0005), axes=(.0252, .0312), angle=-9, power=.96),
        cushion=dict(opening=(.0195, .031), back=-.0035, face=-.0225),
        band=dict(width=.0190, thick=.0135, power=2.2, rise=.0745, end_block=.0105),
        stem=dict(kind='round', radius=.00535, visible=.020, socket=.0145, u=.0005, w=.0152),
        slit='gold',
    ),
    'XM6': dict(
        name='WH-1000XM6',
        cup=dict(a=.0392, widen=1.04, tilt=24, cx=.050, zc=.050, wall=.0094, cap=.0180, cap_power=3.3),
        touch=dict(center=(.0003, -.0018), axes=(.0250, .0250), angle=0, power=1.0),
        cushion=dict(opening=(.0200, .0310), back=-.0035, face=-.0235),
        band=dict(width=.0240, thick=.0152, power=2.3, rise=.0735, end_block=.0060),
        stem=dict(kind='hinged', half=(.0056, .0050), visible=.0235, socket=.0140, u=.0005, w=.0150),
        slit='dark',
    ),
}


# --------------------------------------------------------------------------- scene

def reset_scene():
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob, do_unlink=True)
    for block in (bpy.data.meshes, bpy.data.materials, bpy.data.curves, bpy.data.lights,
                  bpy.data.cameras, bpy.data.worlds, bpy.data.collections):
        for item in list(block):
            block.remove(item)
    scene = bpy.context.scene
    scene.unit_settings.system = 'METRIC'
    return scene


class Kit:
    """Mesh and material helpers bound to one model's collection and name prefix."""

    def __init__(self, scene, prefix):
        self.prefix = prefix
        self.model = bpy.data.collections.new(prefix + ' Headphones')
        scene.collection.children.link(self.model)
        self.studio = bpy.data.collections.new(prefix + ' Studio')
        scene.collection.children.link(self.studio)

    def material(self, name, color, roughness, metallic=0, grain=0, grain_scale=1500):
        mat = bpy.data.materials.new(self.prefix + '_' + name)
        mat.diffuse_color = (*color, 1)
        mat.use_nodes = True
        p = mat.node_tree.nodes.get('Principled BSDF')
        p.inputs['Base Color'].default_value = (*color, 1)
        p.inputs['Roughness'].default_value = roughness
        p.inputs['Metallic'].default_value = metallic
        if grain:
            tex = mat.node_tree.nodes.new('ShaderNodeTexNoise')
            tex.inputs['Scale'].default_value = grain_scale
            tex.inputs['Detail'].default_value = 2
            bump = mat.node_tree.nodes.new('ShaderNodeBump')
            bump.inputs['Strength'].default_value = grain
            bump.inputs['Distance'].default_value = .00009
            mat.node_tree.links.new(tex.outputs['Fac'], bump.inputs['Height'])
            mat.node_tree.links.new(bump.outputs['Normal'], p.inputs['Normal'])
        return mat

    def mesh(self, name, verts, faces, mats, material_indices=None, smooth=True, sharp_angle=None, facing=None):
        """SceneKit culls back faces, so closed parts get outward normals and open parts face `facing`."""
        data = bpy.data.meshes.new(self.prefix + '_' + name)
        data.from_pydata([tuple(v) for v in verts], [], faces)
        data.validate()
        bm = bmesh.new()
        bm.from_mesh(data)
        if facing is None:
            bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
        else:
            bm.normal_update()
            bmesh.ops.reverse_faces(bm, faces=[f for f in bm.faces if f.normal.dot(facing) < 0])
        bm.to_mesh(data)
        bm.free()
        data.update()
        obj = bpy.data.objects.new(self.prefix + '_' + name, data)
        self.model.objects.link(obj)
        for m in (mats if isinstance(mats, (list, tuple)) else [mats]):
            data.materials.append(m)
        if material_indices:
            for poly, index in zip(data.polygons, material_indices):
                poly.material_index = index
        for poly in data.polygons:
            poly.use_smooth = smooth
        if sharp_angle:
            data.set_sharp_from_angle(angle=sharp_angle)
        return obj


def signpow(x, p):
    return math.copysign(abs(x) ** p, x)


def lerp(a, b, t):
    return a + (b - a) * t


def smoothstep(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


# --------------------------------------------------------------------------- earcup frame

class Cup:
    """Earcup coordinates: u toward the wearer's front, v up the cup face, w away from the head."""

    def __init__(self, spec):
        c = spec['cup']
        self.a, self.widen = c['a'], c['widen']
        self.cx, self.zc = c['cx'], c['zc']
        self.wall, self.cap, self.cap_power = c['wall'], c['cap'], c['cap_power']
        self.tilt = math.radians(c['tilt'])
        # Polar lookup of the outline radius, used to find how far any face point is from the rim.
        samples = sorted((math.atan2(v, u), math.hypot(u, v))
                         for u, v in (self.outline(2 * math.pi * i / 4096) for i in range(4096)))
        self.polar_angles = [s[0] for s in samples]
        self.polar_radii = [s[1] for s in samples]
        self.b = max(self.outline(math.pi * i / 512)[1] for i in range(512))

    def outline(self, t, scale=1.0):
        """Traced rim, parametrised by polar angle (0: front, pi/2: top)."""
        r = CUP_OUTLINE[0] + sum(CUP_OUTLINE[2 * k - 1] * math.cos(k * t) + CUP_OUTLINE[2 * k] * math.sin(k * t)
                                 for k in range(1, (len(CUP_OUTLINE) - 1) // 2 + 1))
        return self.a * self.widen * r * math.cos(t) * scale, self.a * r * math.sin(t) * scale

    def outline_normal(self, t):
        e = 1e-4
        u0, v0 = self.outline(t - e)
        u1, v1 = self.outline(t + e)
        n = Vector((v1 - v0, -(u1 - u0)))
        return n.normalized()

    def rim_radius(self, u, v):
        angle = math.atan2(v, u)
        i = bisect_left(self.polar_angles, angle) % len(self.polar_angles)
        j = (i - 1) % len(self.polar_angles)
        a0, a1 = self.polar_angles[j], self.polar_angles[i]
        if a1 < a0:
            a1 += 2 * math.pi
            if angle < a0:
                angle += 2 * math.pi
        f = 0 if a1 == a0 else (angle - a0) / (a1 - a0)
        return lerp(self.polar_radii[j], self.polar_radii[i], f)

    def rho(self, u, v):
        return math.hypot(u, v) / self.rim_radius(u, v)

    def face_height(self, rho):
        """Soft pebble cap: vertical at the rim, almost flat across the touch face."""
        rho = min(1.0, rho)
        return self.wall + self.cap * (1 - rho ** self.cap_power) ** (1 / self.cap_power)

    def point(self, side, u, v, w):
        t = self.tilt
        return Vector((side * (self.cx + math.sin(t) * v + math.cos(t) * w), u,
                       self.zc + math.cos(t) * v - math.sin(t) * w))

    def axes(self, side):
        t = self.tilt
        U = Vector((0, 1, 0))
        V = Vector((side * math.sin(t), 0, math.cos(t)))
        W = Vector((side * math.cos(t), 0, -math.sin(t)))
        return U, V, W


def flip_for_side(faces, side):
    return faces if side > 0 else [tuple(reversed(f)) for f in faces]


def ring_faces(rings, n, closed=True):
    faces = []
    for j in range(rings - 1):
        for i in range(n if closed else n - 1):
            a, b = j * n + i, j * n + (i + 1) % n
            faces.append((a, b, b + n, a + n))
    return faces


# --------------------------------------------------------------------------- earcup parts

def build_shell(kit, cup, spec, side, mats):
    """One closed shell: straight side wall, rounded rim and a touch panel set flush into the face."""
    N = 160
    touch = spec['touch']
    tcu, tcv = touch['center']
    ta, tb = touch['axes']
    rot = math.radians(touch['angle'])

    def touch_boundary(t):
        x = ta * signpow(math.cos(t), touch['power'])
        y = tb * signpow(math.sin(t), touch['power'])
        return (tcu + x * math.cos(rot) - y * math.sin(rot), tcv + x * math.sin(rot) + y * math.cos(rot))

    verts, faces, mat_index = [], [], []
    rings = []
    # Side wall, from the cushion seam to the start of the rounded cap.
    for w, r in [(-.0042, .978), (-.0028, .988), (-.0012, .996), (.002, 1.0), (cup.wall * .6, 1.0), (cup.wall, 1.0)]:
        rings.append([(cup.outline(2 * math.pi * i / N, r), w) for i in range(N)])
    # Cap: rings blend from the rim to the touch panel edge; heights follow the pebble profile.
    K = 22
    for k in range(1, K + 1):
        f = 1 - math.cos(k / K * math.pi / 2)
        f = f ** .82
        ring = []
        for i in range(N):
            t = 2 * math.pi * i / N
            ou, ov = cup.outline(t)
            bu, bv = touch_boundary(t)
            u, v = lerp(ou, bu, f), lerp(ov, bv, f)
            ring.append(((u, v), None))
        rings.append(ring)
    outer_ring_count = len(rings)
    # Touch panel, concentric to its own centre.
    for s in [.8, .6, .42, .26, .13, .04]:
        ring = []
        for i in range(N):
            bu, bv = touch_boundary(2 * math.pi * i / N)
            ring.append(((lerp(tcu, bu, s), lerp(tcv, bv, s)), None))
        rings.append(ring)
    for ring in rings:
        for (u, v), w in ring:
            if w is None:
                w = cup.face_height(cup.rho(u, v))
            verts.append(cup.point(side, u, v, w))
    faces = ring_faces(len(rings), N)
    for j in range(len(rings) - 1):
        mat_index += [1 if j >= outer_ring_count - 1 else 0] * N
    centre = len(verts)
    verts.append(cup.point(side, tcu, tcv, cup.face_height(cup.rho(tcu, tcv))))
    last = (len(rings) - 1) * N
    for i in range(N):
        faces.append((last + i, last + (i + 1) % N, centre))
        mat_index.append(1)
    faces.append(tuple(range(N - 1, -1, -1)))
    mat_index.append(0)
    faces = flip_for_side(faces, side)
    return kit.mesh('Earcup shell' + side_suffix(side), verts, faces, mats, mat_index)


def build_cushion(kit, cup, spec, side, leather):
    c = spec['cushion']
    oa, ob = c['opening']
    back, face = c['back'], c['face']
    N, M = 160, 36
    verts = []
    for i in range(N):
        t = 2 * math.pi * i / N
        ou, ov = cup.outline(t, .99)
        iu, iv = oa * signpow(math.cos(t), .9), ob * signpow(math.sin(t), .9) + .0012
        # A whisper of uneven stitching tension keeps the leather from looking machined.
        crease = .00013 * math.sin(31 * t + 2 * math.sin(5 * t))
        for j in range(M):
            p = 2 * math.pi * j / M
            head_side = max(0.0, math.sin(p))
            e_q, e_d = (.62, .78) if math.sin(p) > 0 else (.18, .22)
            q = .5 + .5 * signpow(math.cos(p), e_q)
            depth = (back + face) / 2 - (back - face) / 2 * signpow(math.sin(p), e_d)
            # Memory foam puffs toward the head and bellies out a little at the outer wall.
            depth -= .0017 * math.sin(math.pi * q) * head_side
            q += .03 * (1 - abs(math.sin(p))) * (1 if math.cos(p) > 0 else -.4)
            u, v = lerp(iu, ou, q), lerp(iv, ov, q)
            n = Vector((u, v)).normalized()
            u += n.x * crease * head_side
            v += n.y * crease * head_side
            verts.append(cup.point(side, u, v, depth))
    faces = []
    for i in range(N):
        for j in range(M):
            a = i * M + j
            b = ((i + 1) % N) * M + j
            faces.append((a, b, ((i + 1) % N) * M + (j + 1) % M, i * M + (j + 1) % M))
    faces = flip_for_side(faces, -side)
    kit.mesh('Memory foam cushion' + side_suffix(side), verts, faces, leather)
    # Recessed driver cloth inside the opening.
    ring_verts = [cup.point(side, oa * 1.06 * signpow(math.cos(2 * math.pi * i / 96), .9),
                            ob * 1.04 * signpow(math.sin(2 * math.pi * i / 96), .9) + .0012, back - .0035)
                  for i in range(96)]
    kit.mesh('Acoustic fabric' + side_suffix(side), ring_verts, [tuple(range(96))], kit.fabric,
             facing=-cup.axes(side)[2])


def build_wall_pill(kit, cup, side, t, w, length, width, name, rim_mat, hole_mat, depth=.00012, rim=True):
    """A small slot (microphone, USB-C or button) sitting on the side wall, long axis around the rim."""
    U, V, W = cup.axes(side)
    u, v = cup.outline(t, 1.0)
    n2 = cup.outline_normal(t)
    tangent2 = Vector((-n2.y, n2.x))
    centre = cup.point(side, u, v, w)
    normal = (U * n2.x + V * n2.y).normalized()
    along = (U * tangent2.x + V * tangent2.y).normalized()
    across = W
    pts = []
    R = width / 2
    straight = max(0.0, length / 2 - R)
    for k in range(64):
        a = 2 * math.pi * k / 64
        x = math.cos(a) * R + math.copysign(straight, math.cos(a))
        y = math.sin(a) * R
        pts.append((x, y))
    # Follow the wall's curvature so the slot never floats off or sinks into the shell.
    def on_wall(x, y, lift):
        theta = t + x / max(1e-6, Vector(cup.outline(t)).length)
        uu, vv = cup.outline(theta, 1.0)
        return cup.point(side, uu, vv, w + y) + (U * cup.outline_normal(theta).x + V * cup.outline_normal(theta).y) * lift
    hole = [on_wall(x * .82, y * .7, depth * .5) for x, y in pts]
    kit.mesh(name, hole, [tuple(range(64))], hole_mat, facing=normal)
    if rim:
        ring = [on_wall(x, y, depth) for x, y in pts]
        inner = [on_wall(x * .82, y * .7, depth) for x, y in pts]
        verts = ring + inner
        faces = [(k, (k + 1) % 64, 64 + (k + 1) % 64, 64 + k) for k in range(64)]
        kit.mesh(name + ' rim', verts, faces, rim_mat, facing=normal)
    return centre, normal, along


def side_suffix(side):
    return ' R' if side > 0 else ' L'


# --------------------------------------------------------------------------- sweeps

def sweep(kit, name, path, section, mat, cap_start=None, cap_end=None, binormal=Vector((0, 1, 0))):
    """Sweep a 2D section (callable of station index -> list of (b, n) offsets) along a planar path.

    b runs along `binormal`, n along the in-plane normal. Caps are rounded domes of the given length."""
    pts = [Vector(p) for p in path]
    frames = []
    for i, p in enumerate(pts):
        tangent = (pts[min(i + 1, len(pts) - 1)] - pts[max(i - 1, 0)]).normalized()
        normal = tangent.cross(binormal).normalized()
        frames.append((p, tangent, normal))
    rings = []
    def add_ring(p, normal, offsets, scale=1.0, shift=Vector()):
        rings.append([p + shift + binormal * (b * scale) + normal * (n * scale) for b, n in offsets])
    if cap_start:
        p, tangent, normal = frames[0]
        offs = section(0)
        for k in range(5, 0, -1):
            a = k / 5 * math.pi / 2
            add_ring(p, normal, offs, max(.12, math.cos(a)), -tangent * cap_start * math.sin(a))
    for i, (p, tangent, normal) in enumerate(frames):
        add_ring(p, normal, section(i))
    if cap_end:
        p, tangent, normal = frames[-1]
        offs = section(len(frames) - 1)
        for k in range(1, 6):
            a = k / 5 * math.pi / 2
            add_ring(p, normal, offs, max(.12, math.cos(a)), tangent * cap_end * math.sin(a))
    n = len(rings[0])
    verts = [v for ring in rings for v in ring]
    faces = ring_faces(len(rings), n)
    faces.append(tuple(range(n - 1, -1, -1)))
    last = (len(rings) - 1) * n
    faces.append(tuple(last + i for i in range(n)))
    return kit.mesh(name, verts, faces, mat)


def superellipse_section(half_b, half_n, pb=.5, pn=.5, count=32, bulge=0.0):
    out = []
    for j in range(count):
        a = 2 * math.pi * j / count
        b = half_b * signpow(math.cos(a), pb)
        n = half_n * signpow(math.sin(a), pn)
        # Padding is fuller across the middle of the band than at its edges.
        n += bulge * math.sin(a) * (1 - abs(math.cos(a)) ** 2)
        out.append((b, n))
    return out


def recalc_normals(obj):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    bm.to_mesh(obj.data)
    bm.free()


# --------------------------------------------------------------------------- headband and stems

def band_path(spec, half_span, base_z, count=180, t0=0.0, t1=math.pi):
    band = spec['band']
    e = 2 / band['power']
    pts = []
    for i in range(count + 1):
        t = lerp(t0, t1, i / count)
        x = -half_span * signpow(math.cos(t), e)
        z = base_z + band['rise'] * signpow(math.sin(t), e)
        pts.append((x, 0, z))
    return pts


def build_headband(kit, spec, rod_x, base_z, mats):
    band = spec['band']
    W, T = band['width'], band['thick']
    # Straight vertical legs continue the arch down into the end blocks.
    leg = [(-rod_x, 0, base_z - .002 - .0015 * k) for k in range(3, 0, -1)]
    arch = band_path(spec, rod_x, base_z)
    path = leg + arch + [(rod_x, 0, base_z - .002 - .0015 * k) for k in range(1, 4)]
    section = superellipse_section(W / 2, T / 2, .3, .5, 48, bulge=.0007)
    obj = sweep(kit, 'Padded headband', path, lambda i: section, mats['leather'], cap_start=.0015, cap_end=.0015)
    recalc_normals(obj)
    # End blocks house the sliders; slightly proud of the leather so the joint reads as a part line.
    for s in (-1, 1):
        top = base_z - .0006
        bottom = base_z - .0065 - band['end_block']
        path = [(s * rod_x, 0, lerp(top, bottom, k / 12)) for k in range(13)]
        block_section = superellipse_section(W / 2 * 1.02, T / 2 * 1.03, .3, .45, 48)
        obj = sweep(kit, 'Slider housing' + side_suffix(s), path, lambda i: block_section, mats['yoke'],
                    cap_end=.0032)
        recalc_normals(obj)
    return base_z - .0065 - band['end_block']


def wrap_text(kit, name, text, mat, size, place):
    """Lettering converted to mesh, then bent onto the stem with `place(local) -> world`."""
    curve = bpy.data.curves.new(kit.prefix + '_' + name, 'FONT')
    curve.body = text
    curve.size = size
    curve.align_x, curve.align_y = 'CENTER', 'CENTER'
    curve.extrude = .00002
    curve.bevel_depth = .000006
    curve.bevel_resolution = 2
    curve.resolution_u = 6
    for path in ['/System/Library/Fonts/Supplemental/SuperClarendon.ttc',
                 '/System/Library/Fonts/Supplemental/Times New Roman Bold.ttf']:
        if Path(path).exists():
            curve.font = bpy.data.fonts.load(path, check_existing=True)
            break
    tmp = bpy.data.objects.new('tmp_text', curve)
    kit.model.objects.link(tmp)
    dg = bpy.context.evaluated_depsgraph_get()
    mesh = bpy.data.meshes.new_from_object(tmp.evaluated_get(dg))
    bpy.data.objects.remove(tmp, do_unlink=True)
    bpy.data.curves.remove(curve)
    for v in mesh.vertices:
        v.co = place(v.co.copy())
    mesh.name = kit.prefix + '_' + name
    obj = bpy.data.objects.new(kit.prefix + '_' + name, mesh)
    kit.model.objects.link(obj)
    mesh.materials.append(mat)
    for poly in mesh.polygons:
        poly.use_smooth = False
    return obj


class StemFrame:
    """A stem's local frame: s along its axis (up), n toward the outside of the headband, b toward the front."""

    def __init__(self, cup, spec, side):
        st = spec['stem']
        self.side = side
        self.origin = cup.point(side, st['u'], cup.b - st['socket'], st['w'])
        lean = math.radians(st.get('lean', 8))
        self.D = Vector((side * math.sin(lean), 0, math.cos(lean)))
        self.B = Vector((0, 1, 0))
        self.N = self.B.cross(self.D).normalized() * (1 if side > 0 else -1)
        if self.N.x * side < 0:
            self.N = -self.N

    def at(self, s, n=0.0, b=0.0):
        return self.origin + self.D * s + self.N * n + self.B * b

    def length_to(self, z):
        return (z - self.origin.z) / self.D.z


def stem_mesh(kit, frame, name, section, s0, s1, mat, s0_tilt=0.0, s1_tilt=0.0, round_start=False, rows=24):
    """A prism along the stem axis; ends may be sheared onto an inclined plane (s += tilt * n)."""
    verts = []
    for k in range(rows + 1):
        f = k / rows
        for b, n in section:
            s = lerp(s0 + s0_tilt * n, s1 + s1_tilt * n, f)
            scale = 1.0
            if round_start and f < .18:
                # Rounded pivot end that disappears into the socket.
                scale = math.sqrt(max(0.0, 1 - ((.18 - f) / .18) ** 2)) * .45 + .55
            verts.append(frame.at(s, n * scale, b * scale))
    count = len(section)
    faces = ring_faces(rows + 1, count)
    faces.append(tuple(range(count - 1, -1, -1)))
    faces.append(tuple(rows * count + i for i in range(count)))
    return kit.mesh(name, verts, faces, mat)


def build_round_stem(kit, cup, spec, side, top_z, mats):
    st = spec['stem']
    r = st['radius']
    frame = StemFrame(cup, spec, side)
    top = frame.length_to(top_z) + .003
    seam = top - .0128
    sec = superellipse_section(r, r, 1, 1, 40)
    stem_mesh(kit, frame, 'Hanger stem' + side_suffix(side), sec, 0, seam - .00035, mats['yoke'], round_start=True)
    sec_u = superellipse_section(r * 1.025, r * 1.025, 1, 1, 40)
    stem_mesh(kit, frame, 'Slider rail' + side_suffix(side), sec_u, seam + .00035, top, mats['yoke'], rows=10)
    centre = frame.at(seam - .0092)

    def place(co):
        phi = co.y / r
        radial = r + .00004 + co.z
        return centre - frame.D * co.x + (frame.N * math.cos(phi) + frame.B * side * math.sin(phi)) * radial
    wrap_text(kit, 'Sony branding' + side_suffix(side), 'SONY', mats['gold'], .0034, place)
    return frame


def build_hinged_stem(kit, cup, spec, side, top_z, mats):
    """XM6: squared stem with a diagonal folding hinge and a brushed metal knuckle."""
    st = spec['stem']
    hb, hn = st['half']
    frame = StemFrame(cup, spec, side)
    top = frame.length_to(top_z) + .003
    hinge = top - .0150
    tilt = math.tan(math.radians(34))  # hinge plane rises toward the outside of the headband
    sec = superellipse_section(hb, hn, .32, .32, 48)
    lower = stem_mesh(kit, frame, 'Hanger stem' + side_suffix(side), sec, 0, hinge - .0009, mats['yoke'],
                      s1_tilt=tilt, round_start=True)
    upper = stem_mesh(kit, frame, 'Fold arm' + side_suffix(side), sec, hinge + .0009, top, mats['yoke'],
                      s0_tilt=tilt, rows=10)
    for obj in (lower, upper):
        bev = obj.modifiers.new('Machined edge', 'BEVEL')
        bev.width, bev.segments, bev.limit_method, bev.angle_limit = .0003, 3, 'ANGLE', math.radians(35)
    plate_sec = superellipse_section(hb * .96, hn * .96, .32, .32, 48)
    stem_mesh(kit, frame, 'Hinge knuckle' + side_suffix(side), plate_sec, hinge - .00092, hinge + .00092,
              kit.material('Brushed knuckle', (.16, .165, .17), .28, .9), s0_tilt=tilt, s1_tilt=tilt, rows=1)
    # Hinge pin cap on the front face, on the fold axis.
    pin = [frame.at(hinge + .0012 * math.sin(2 * math.pi * k / 32) + tilt * .0012,
                    .0012 + .0012 * math.cos(2 * math.pi * k / 32), hb + .00005) for k in range(32)]
    kit.mesh('Hinge pin' + side_suffix(side), pin, [tuple(range(32))], mats['metal'], facing=frame.B)
    centre = frame.at(hinge - .0118, hn + .00005)

    def place(co):
        return centre - frame.D * co.x + frame.B * side * co.y + frame.N * co.z
    wrap_text(kit, 'Sony branding' + side_suffix(side), 'SONY', mats['gold'], .0032, place)
    return frame


def cut_socket(kit, cup, spec, side, shell):
    """Boolean slot in the top of the cup that the stem drops into, open toward the outer face."""
    st = spec['stem']
    half = st['radius'] if st['kind'] == 'round' else st['half'][0]
    half_n = st['radius'] if st['kind'] == 'round' else st['half'][1]
    U, V, W = cup.axes(side)
    frame = StemFrame(cup, spec, side)
    # The stem leans less than the cup, so it drifts toward the head as it rises through the socket.
    drift = st['socket'] * math.tan(cup.tilt - math.asin(abs(frame.D.x)))
    u0, u1 = st['u'] - half - .0009, st['u'] + half + .0009
    v0, v1 = cup.b - st['socket'] - .0012, cup.b + .03
    w0, w1 = st['w'] - drift - half_n - .0009, st['w'] + .05
    corners = [cup.point(side, u, v, w) for u in (u0, u1) for v in (v0, v1) for w in (w0, w1)]
    faces = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
    cutter = kit.mesh('socket cutter', corners, faces, kit.fabric, smooth=False)
    bev = cutter.modifiers.new('round', 'BEVEL')
    bev.width, bev.segments = .0016, 4
    mod = shell.modifiers.new('Stem socket', 'BOOLEAN')
    mod.operation, mod.solver, mod.object = 'DIFFERENCE', 'EXACT', cutter
    dg = bpy.context.evaluated_depsgraph_get()
    mesh = bpy.data.meshes.new_from_object(shell.evaluated_get(dg))
    old = shell.data
    shell.modifiers.clear()
    shell.data = mesh
    bpy.data.meshes.remove(old)
    bpy.data.objects.remove(cutter, do_unlink=True)
    mesh.name = shell.name
    mesh.set_sharp_from_angle(angle=math.radians(38))


# --------------------------------------------------------------------------- assembly

def build_model(scene, key):
    spec = SPECS[key]
    kit = Kit(scene, key)
    mats = {
        'shell': kit.material('Matte shell', (.017, .018, .021), .54, grain=.10),
        'touch': kit.material('Touch panel', (.056, .058, .062), .60, grain=.04),
        'yoke': kit.material('Yoke', (.019, .020, .023), .50, grain=.08),
        'leather': kit.material('Leather', (.016, .017, .019), .55, grain=.20),
        'seam': kit.material('Seam', (.006, .007, .009), .55),
        'gold': kit.material('Copper', (.50, .30, .12), .30, .75),
        'metal': kit.material('Anodized', (.075, .078, .085), .32, .75),
        'hole': kit.material('Port', (.004, .004, .005), .7),
    }
    kit.fabric = kit.material('Fabric', (.009, .010, .012), .93, grain=.5, grain_scale=3300)
    cup = Cup(spec)
    stem = spec['stem']
    cup_top = cup.point(1, stem['u'], cup.b, stem['w']).z
    rod_top = cup_top + stem['visible']
    band_base = rod_top + spec['band']['end_block'] + .0065
    frame = StemFrame(cup, spec, 1)
    rod_x = frame.at(frame.length_to(rod_top)).x
    build_headband(kit, spec, rod_x, band_base, mats)
    for side in (-1, 1):
        shell = build_shell(kit, cup, spec, side, [mats['shell'], mats['touch']])
        cut_socket(kit, cup, spec, side, shell)
        build_cushion(kit, cup, spec, side, mats['leather'])
        if stem['kind'] == 'round':
            build_round_stem(kit, cup, spec, side, rod_top, mats)
        else:
            build_hinged_stem(kit, cup, spec, side, rod_top, mats)
        slit_rim = mats['gold'] if spec['slit'] == 'gold' else mats['seam']
        # Feed-forward and voice microphones on the front and back walls.
        for t, w, length in [(math.radians(8), .0040, .0068), (math.radians(-64), .0036, .0040),
                             (math.radians(168), .0040, .0052)]:
            build_wall_pill(kit, cup, side, t, w, length, .0019, 'Microphone %d%s' % (round(math.degrees(t)), side_suffix(side)),
                            slit_rim, mats['hole'])
        if side > 0:
            build_wall_pill(kit, cup, side, math.radians(-96), .0040, .0088, .0030, 'USB-C port', mats['metal'], mats['hole'])
        else:
            for t, name in [(math.radians(-118), 'POWER button'), (math.radians(-134), 'NC-AMB button')]:
                build_wall_pill(kit, cup, side, t, .0040, .0046, .0018, name, mats['yoke'], mats['yoke'], depth=.00045)
    # Small red tactile "L" marker on the inside of the left slider housing.
    inner = -rod_x + spec['band']['thick'] / 2 * 1.06 + .00012
    marker = [Vector((inner, .0019 * math.cos(2 * math.pi * k / 32),
                      band_base - .0065 - spec['band']['end_block'] / 2 + .0019 * math.sin(2 * math.pi * k / 32)))
              for k in range(32)]
    kit.mesh('Left marker', marker, [tuple(range(32))], kit.material('Marker', (.45, .03, .03), .45),
             facing=Vector((1, 0, 0)))
    # Match the XM4 study's overall height so the app frames every model at the same size.
    centre, size = frame_target(kit)
    factor = XM4_HEIGHT / size.z
    for ob in kit.model.objects:
        if ob.type == 'MESH':
            ob.data.transform(Matrix.Scale(factor, 4))
    return kit, spec


def build_studio(scene, kit):
    world = bpy.data.worlds.new(kit.prefix + ' Studio world')
    world.use_nodes = True
    world.node_tree.nodes['Background'].inputs[0].default_value = (.16, .18, .22, 1)
    world.node_tree.nodes['Background'].inputs[1].default_value = .35
    scene.world = world

    def area(name, loc, power, size, color):
        data = bpy.data.lights.new(name, 'AREA')
        data.energy, data.shape, data.size, data.color = power, 'DISK', size, color
        ob = bpy.data.objects.new(name, data)
        kit.studio.objects.link(ob)
        ob.location = loc
        ob.rotation_euler = (Vector((0, 0, .105)) - ob.location).to_track_quat('-Z', 'Y').to_euler()
    area('Key softbox', (.22, -.24, .38), 3, .28, (.88, .93, 1))
    area('Warm fill', (-.23, -.10, .22), 1.8, .24, (1, .89, .76))
    area('Rim strip', (.05, .22, .32), 4, .20, (.75, .84, 1))
    camdata = bpy.data.cameras.new(kit.prefix + ' Camera')
    cam = bpy.data.objects.new(kit.prefix + ' Camera', camdata)
    kit.studio.objects.link(cam)
    cam.location = (.34, -.46, .27)
    cam.rotation_euler = (Vector((0, 0, .108)) - cam.location).to_track_quat('-Z', 'Y').to_euler()
    camdata.type, camdata.ortho_scale = 'ORTHO', .275
    scene.camera = cam
    scene.render.engine = 'CYCLES'
    scene.cycles.samples = 32
    scene.cycles.use_denoising = True
    try:
        prefs = bpy.context.preferences.addons['cycles'].preferences
        prefs.compute_device_type = 'METAL'
        prefs.get_devices()
        for d in prefs.devices:
            d.use = True
        scene.cycles.device = 'GPU'
    except Exception:
        pass
    scene.render.resolution_x = scene.render.resolution_y = 1100
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = 'PNG'
    scene.render.film_transparent = True
    scene.view_settings.view_transform = 'AgX'


def frame_target(kit):
    pts = [o.matrix_world @ Vector(c) for o in kit.model.objects if o.type == 'MESH' for c in o.bound_box]
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    return (lo + hi) / 2, hi - lo


def aim(cam, location, target):
    cam.location = location
    cam.rotation_euler = (target - cam.location).to_track_quat('-Z', 'Y').to_euler()


def export(scene, kit, spec):
    name = spec['name']
    centre, size = frame_target(kit)
    # Same 3/4 studio angle as the XM4 thumbnail, re-aimed at this model's centre.
    aim(scene.camera, centre + Vector((.34, -.46, .27 - .108)), centre)
    bpy.context.view_layer.update()
    blend = ROOT / 'artwork' / (name + '.blend')
    bpy.data.libraries.write(str(blend), {scene}, path_remap='RELATIVE', fake_user=True, compress=True)
    for ob in scene.objects:
        ob.select_set(False)
    for ob in kit.model.objects:
        ob.select_set(True)
    bpy.ops.wm.usd_export(filepath=str(OUT / (name + '.usdz')), selected_objects_only=True, export_animation=False,
                          export_lights=False, export_cameras=False, export_materials=True,
                          generate_preview_surface=True, generate_materialx_network=False, convert_orientation=True,
                          export_global_forward_selection='NEGATIVE_Z', export_global_up_selection='Y',
                          export_textures_mode='NEW', overwrite_textures=True)
    scene.render.filepath = str(OUT / (name + '.png'))
    bpy.ops.render.render(write_still=True)
    print('EXPORTED', name, len(kit.model.objects), 'objects',
          sum(len(o.data.vertices) for o in kit.model.objects if o.type == 'MESH'), 'vertices')


def preview(scene, kit, spec, folder):
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    centre, size = frame_target(kit)
    cam = scene.camera
    scene.render.resolution_x = scene.render.resolution_y = 700
    scene.cycles.samples = 24
    views = {
        'hero': (Vector((.34, -.46, .27 - .108)), .275),
        'front': (Vector((0, .6, 0)), .23),
        'back': (Vector((0, -.6, 0)), .23),
        'side': (Vector((.6, 0, 0)), .23),
        'below': (Vector((.25, -.3, -.35)), .26),
        'inside': (Vector((-.42, .38, .12)), .26),
        'detail': (Vector((.30, -.20, .10)), .11),
        'socket': (Vector((.30, .12, .14)), .06),
        'bottom': (Vector((.10, .05, -.40)), .16),
    }
    only = set(sys.argv[sys.argv.index('--') + 1:]) & set(views)
    for view, (offset, scale) in views.items():
        if only and view not in only:
            continue
        target = {'detail': centre + Vector((.06, 0, .03)), 'socket': centre + Vector((.09, 0, .0))}.get(view, centre)
        aim(cam, target + offset, target)
        cam.data.ortho_scale = scale
        scene.render.filepath = str(folder / ('%s-%s.png' % (spec['name'], view)))
        bpy.ops.render.render(write_still=True)


def main():
    args = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else ['XM5', 'XM6']
    keys = [a for a in args if a in SPECS] or ['XM5', 'XM6']
    preview_dir = args[args.index('preview') + 1] if 'preview' in args else None
    for key in keys:
        scene = reset_scene()
        kit, spec = build_model(scene, key)
        build_studio(scene, kit)
        if preview_dir:
            preview(scene, kit, spec, preview_dir)
        else:
            OUT.mkdir(parents=True, exist_ok=True)
            export(scene, kit, spec)


main()
