"""Original WH-1000XM4 study, built in Blender. Run in Blender's Python context.
All geometry and materials are authored here; reference photographs are not bundled.
"""
import bpy
import math
import bmesh
from mathutils import Vector, Matrix
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'Resources/Models'
OUT.mkdir(parents=True, exist_ok=True)
scene_name = 'XM4 Product Studio'
if scene_name in bpy.data.scenes:
    old = bpy.data.scenes[scene_name]
    for obj in list(old.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    bpy.data.scenes.remove(old)
scene = bpy.data.scenes.new(scene_name)
bpy.context.window.scene = scene
scene.unit_settings.system = 'METRIC'
model = bpy.data.collections.new('XM4 Headphones')
scene.collection.children.link(model)
studio = bpy.data.collections.new('XM4 Studio')
scene.collection.children.link(studio)


def material(name, color, roughness, metallic=0, grain=0):
    mat = bpy.data.materials.new('XM4_' + name)
    mat.diffuse_color = (*color, 1)
    mat.use_nodes = True
    p = mat.node_tree.nodes.get('Principled BSDF')
    p.inputs['Base Color'].default_value = (*color, 1)
    p.inputs['Roughness'].default_value = roughness
    p.inputs['Metallic'].default_value = metallic
    if grain:
        tex = mat.node_tree.nodes.new('ShaderNodeTexNoise')
        tex.inputs['Scale'].default_value = 1500 if name != 'Fabric' else 3300
        tex.inputs['Detail'].default_value = 2
        bump = mat.node_tree.nodes.new('ShaderNodeBump')
        bump.inputs['Strength'].default_value = grain
        bump.inputs['Distance'].default_value = .00009
        mat.node_tree.links.new(tex.outputs['Fac'], bump.inputs['Height'])
        mat.node_tree.links.new(bump.outputs['Normal'], p.inputs['Normal'])
    return mat

shell = material('Graphite', (.023,.025,.028), .51, grain=.12)
yoke = material('Yoke', (.021,.023,.026), .49, grain=.1)
leather = material('Leather', (.014,.015,.017), .53, grain=.23)
fabric = material('Fabric', (.009,.010,.012), .93, grain=.5)
seam = material('Seam', (.006,.007,.009), .55)
gold = material('Copper', (.46,.235,.075), .28, .72)
metal = material('Anodized', (.065,.07,.078), .29, .7)
label = material('Lettering', (.16,.17,.18), .5)
led = material('LED', (.11,.24,.43), .3)


def mesh(name, verts, faces, mat):
    data = bpy.data.meshes.new('XM4_' + name)
    data.from_pydata(verts, [], faces)
    data.update()
    bm=bmesh.new();bm.from_mesh(data)
    bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces))
    bm.to_mesh(data);bm.free()
    obj = bpy.data.objects.new('XM4_' + name, data)
    model.objects.link(obj)
    data.materials.append(mat)
    for p in data.polygons: p.use_smooth = True
    return obj


def signpow(x, p): return math.copysign(abs(x)**p, x)

def oval(t, a, b, power=.89):
    return a*signpow(math.cos(t),power), b*signpow(math.sin(t),power)


def cup_point(side, u, v, w):
    tilt=math.radians(18)
    return (side*(.069 + math.sin(tilt)*v + math.cos(tilt)*w), u,
            .052 + math.cos(tilt)*v - math.sin(tilt)*w)


def cup_surface(name, side, rings, a, b, mat, center_v=0):
    N=112
    verts=[]
    for w,r in rings:
        for i in range(N):
            u,v=oval(2*math.pi*i/N,a*r,b*r)
            verts.append(cup_point(side,u,v+center_v,w))
    faces=[]
    for j in range(len(rings)-1):
        for i in range(N):
            face=(j*N+i,j*N+(i+1)%N,(j+1)*N+(i+1)%N,(j+1)*N+i)
            faces.append(face if side>0 else face[::-1])
    faces.append(tuple(range(N-1,-1,-1)) if side>0 else tuple(range(N)))
    end=tuple((len(rings)-1)*N+i for i in range(N))
    faces.append(end if side>0 else end[::-1])
    return mesh(name,verts,faces,mat)


def tube(name, pts, radius, mat, sides=8):
    # Stable local frame, seamless circular cross-section along a path.
    verts=[]
    for i,p in enumerate(pts):
        tangent=Vector(pts[min(i+1,len(pts)-1)])-Vector(pts[max(i-1,0)])
        tangent.normalize()
        axis=Vector((0,0,1)) if abs(tangent.z)<.9 else Vector((0,1,0))
        n=tangent.cross(axis).normalized(); b=tangent.cross(n).normalized()
        for j in range(sides):
            v=Vector(p)+radius*(math.cos(j*2*math.pi/sides)*n+math.sin(j*2*math.pi/sides)*b)
            verts.append(tuple(v))
    faces=[]
    for i in range(len(pts)-1):
        for j in range(sides):faces.append((i*sides+j,i*sides+(j+1)%sides,(i+1)*sides+(j+1)%sides,(i+1)*sides+j))
    return mesh(name,verts,faces,mat)


def arc_band(name,start,end,radial,half_width,half_depth,mat):
    N=100; M=24
    verts=[]
    for i in range(N+1):
        t=start+(end-start)*i/N
        x=.085*math.sin(t);z=.120+.096*math.cos(t)
        n=Vector((math.sin(t),0,math.cos(t)))
        for j in range(M):
            phi=2*math.pi*j/M
            width=half_width*signpow(math.cos(phi),.45)
            depth=radial+half_depth*signpow(math.sin(phi),.6)
            verts.append(tuple(Vector((x,width,z))+n*depth))
    faces=[]
    for i in range(N):
        for j in range(M):faces.append((i*M+j,i*M+(j+1)%M,(i+1)*M+(j+1)%M,(i+1)*M+j))
    faces += [tuple(range(M-1,-1,-1)),tuple(N*M+i for i in range(M))]
    return mesh(name,verts,faces,mat)


def rounded_box(name,loc,scale,mat,bevel=.001):
    bpy.ops.mesh.primitive_cube_add(size=1,location=loc)
    obj=bpy.context.object;obj.name='XM4_'+name
    for c in list(obj.users_collection):c.objects.unlink(obj)
    model.objects.link(obj)
    obj.dimensions=scale
    bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
    obj.data.materials.append(mat)
    modifier=obj.modifiers.new('Manufactured edge radii','BEVEL');modifier.width=bevel;modifier.segments=5
    modifier=obj.modifiers.new('Weighted surface normals','WEIGHTED_NORMAL')
    return obj


def surface_text(name,text,side,u,v,w,size,mat):
    c=bpy.data.curves.new('XM4_'+name,'FONT');c.body=text;c.size=size
    c.align_x='CENTER';c.align_y='CENTER';c.extrude=.000015;c.bevel_depth=.000006;c.bevel_resolution=2
    obj=bpy.data.objects.new('XM4_'+name,c);model.objects.link(obj);c.materials.append(mat)
    tilt=math.radians(18)
    U=Vector((0,side,0));V=Vector((side*math.sin(tilt),0,math.cos(tilt)));N=U.cross(V)
    obj.rotation_euler=Matrix((U,V,N)).transposed().to_euler()
    obj.location=cup_point(side,u,v,w)
    return obj

# Continuous spring, padded crown, and separately manufactured telescoping sleeves.
arc_band('Spring',-1.54,1.54,0,.0123,.0034,metal)
arc_band('Crown shell',-.90,.90,.002,.0154,.0035,shell)
arc_band('Crown cushion',-.88,.88,-.0045,.0145,.0038,leather)
for s in [-1,1]:
    a,b=sorted([s*.92,s*1.54])
    arc_band('Slider sleeve '+str(s),a,b,.0018,.0122,.0042,yoke)

for s in [-1,1]:
    suffix=' L' if s<0 else ' R'
    cup_surface('Earcup body'+suffix,s,[(-.006,.92),(-.004,.98),(0,1),(.009,1),(.017,.96),(.022,.86),(.024,.65),(.0245,.20),(.0245,.001)],.037,.049,shell)
    cup_surface('Face parting line'+suffix,s,[(.0215,.86),(.0222,.87),(.0229,.86)],.037,.043,seam,center_v=-.005)
    cup_surface('Touch plate'+suffix,s,[(.0228,.848),(.0237,.84),(.025,.73),(.0258,.45),(.026,.001)],.037,.043,shell,center_v=-.005)
    cup_surface('Cushion mounting lip'+suffix,s,[(-.006,.97),(-.0075,.98),(-.009,.96)],.037,.049,seam)
    # Cushions have a real open cavity and a soft, slightly irregular leather roll.
    N=144;M=32;verts=[];faces=[]
    for i in range(N):
        t=2*math.pi*i/N
        for j in range(M):
            p=2*math.pi*j/M
            crease=.00016*math.sin(29*t+2*math.sin(7*t))*(.3+.7*max(0,math.sin(p)))
            a=.026+.0097*math.cos(p)+crease
            b=.0374+.0105*math.cos(p)+crease
            u,v=oval(t,a,b,.84)
            w=-.0165+.0107*math.sin(p)
            verts.append(cup_point(s,u,v,w))
    for i in range(N):
        for j in range(M):
            face=(i*M+j,((i+1)%N)*M+j,((i+1)%N)*M+(j+1)%M,i*M+(j+1)%M)
            faces.append(face if s>0 else face[::-1])
    mesh('Memory foam cushion'+suffix,verts,faces,leather)
    cup_surface('Recessed acoustic fabric'+suffix,s,[(-.007,.57),(-.008,.5),(-.0088,.01)],.037,.049,fabric)
    # Stitch/parting welts and inner fabric seam.
    for a,b,w,rad in [(.0354,.047,-.018,.00023),(.0169,.0277,-.013,.00024)]:
        pts=[cup_point(s,*oval(2*math.pi*i/144,a,b,.84),w) for i in range(145)]
        tube('Leather welt'+suffix+str(a),pts,rad,seam)
    # One continuous molded support: the shoulder fans into a flush upper-cup
    # flange. It is a closed shell, not a separate open tube around the cup.
    N=128; M=24; verts=[]; faces=[]
    for back in [False, True]:
        for i in range(N+1):
            base_angle=.10+(math.pi-.20)*i/N
            for j in range(M+1):
                q=j/M
                # Round the arm ends in the surface itself, instead of leaving
                # a square cut or the open end of a swept tube.
                rounding=.10*abs(2*q-1)**2*abs(math.cos(base_angle))**10
                angle=base_angle+math.copysign(rounding,math.cos(base_angle))
                inner_u,inner_v=oval(angle,.0325,.0435,.89)
                outer_u,outer_v=oval(angle,.0385,.050,.89)
                blend=max(0,min(1,(.031-abs(outer_u))/(.031-.0122)))
                blend=(blend*blend*(3-2*blend))**1.6
                outer_v=outer_v*(1-blend)+.075*blend
                shoulder=max(0,min(1,(outer_v-.050)/.025))
                outer_w=.011-.012*shoulder
                u=inner_u*(1-q)+outer_u*q
                v=inner_v*(1-q)+outer_v*q
                w=.0245*(1-q)+outer_w*q+.0015*math.sin(math.pi*q)
                verts.append(cup_point(s,u,v,w-(.003 if back else 0)))
    stride=M+1
    layer=(N+1)*stride
    for i in range(N):
        for j in range(M):
            k=i*stride+j
            faces.append((k,k+1,k+stride+1,k+stride))
            faces.append((layer+k+stride,layer+k+stride+1,layer+k+1,layer+k))
    # Close all four boundary edges, including the rounded arm tips.
    boundary=([i*stride for i in range(N+1)]
              +[N*stride+j for j in range(1,M+1)]
              +[i*stride+M for i in range(N-1,-1,-1)]
              +[j for j in range(M-1,0,-1)])
    for i,k in enumerate(boundary):
        nxt=boundary[(i+1)%len(boundary)]
        faces.append((k,layer+k,layer+nxt,nxt))
    support=mesh('Integrated swivel support'+suffix,verts,faces,yoke)
    bevel=support.modifiers.new('Rounded molded edges','BEVEL')
    bevel.width=.00065;bevel.segments=3
    bevel.limit_method='ANGLE';bevel.angle_limit=.5
    # Copper microphone bezel with recessed black grille.
    pts=[]
    for i in range(97):
        u,v=oval(2*math.pi*i/96,.0042,.00155,.55)
        pts.append(cup_point(s,u,v+.035,.0258))
    tube('Copper microphone bezel'+suffix,pts,.00038,gold,10)
    # Recessed dark slot surface, distinct from the copper lip.
    uv=[oval(2*math.pi*i/64,.0038,.00125,.55) for i in range(64)]
    verts=[cup_point(s,u,v+.035,.02555) for u,v in uv]
    mesh('Microphone recess'+suffix,verts,[tuple(range(64)) if s>0 else tuple(range(63,-1,-1))],fabric)
    for k in range(-5,6):
        pts=[cup_point(s,k*.0006,v+.035,.02565) for v in [-.0008,.0008]]
        tube('Mic grille'+suffix+str(k),pts,.00006,metal,6)
    text=surface_text('Sony branding'+suffix,'SONY',s,0,.069,.020,.0085,gold)
    text.location=cup_point(s,0,.061,.01196)
    U=Vector((0,s,0));V=Vector((-s*.373,0,.928));N=U.cross(V)
    text.rotation_euler=Matrix((U,V,N)).transposed().to_euler()
    font=Path('/System/Library/Fonts/Supplemental/Times New Roman Bold.ttf')
    if font.exists():
        text.data.font=bpy.data.fonts.load(str(font))
    if s<0:
        surface_text('NFC mark','N',s,0,-.025,.0252,.004,label)
    else:
        # Right earcup USB-C charging socket and charge indicator.
        pts=[cup_point(s,*((lambda uv:(uv[0],uv[1]-.041))(oval(2*math.pi*i/64,.0041,.0016,.55))),.0175) for i in range(65)]
        tube('USB-C rim',pts,.00028,metal)
        verts=[cup_point(s,u,v-.041,.0174) for u,v in [oval(2*math.pi*i/64,.0039,.0014,.55) for i in range(64)]]
        mesh('USB-C cavity',verts,[tuple(range(64))],seam)
        pts=[cup_point(s,u,v-.041,.0176) for u,v in [(-.0024,0),(.0024,0)]]
        tube('USB-C tongue',pts,.00028,shell)
    if s<0:
        # Analogue input and the two left-hand buttons.
        pts=[cup_point(s,.006+.0018*math.cos(2*math.pi*i/64),-.041+.0018*math.sin(2*math.pi*i/64),.0175) for i in range(65)]
        tube('3.5 mm jack',pts,.00045,metal)
        for v,title in [(-.009,'POWER'),(-.024,'CUSTOM')]:
            pts=[cup_point(s,u,v+.003*math.cos(2*math.pi*i/64),.014) for i in range(65) for u in [-.034+.0011*math.sin(2*math.pi*i/64)]]
            tube(title+' button',pts,.00065,yoke)
    # Product model designation is omitted from the underside at this viewing scale.

# Studio rig is retained in the .blend, but never shipped in the runtime USDZ.
world=bpy.data.worlds.new('XM4 Studio world');world.use_nodes=True
world.node_tree.nodes['Background'].inputs[0].default_value=(.16,.18,.22,1)
world.node_tree.nodes['Background'].inputs[1].default_value=.35
scene.world=world

def area(name,loc,power,size,color):
    data=bpy.data.lights.new(name,'AREA');data.energy=power;data.shape='DISK';data.size=size;data.color=color
    ob=bpy.data.objects.new(name,data);studio.objects.link(ob);ob.location=loc
    ob.rotation_euler=(Vector((0,0,.105))-ob.location).to_track_quat('-Z','Y').to_euler()
area('Key softbox',(.22,-.24,.38),3,.28,(.88,.93,1))
area('Warm fill',(-.23,-.10,.22),1.8,.24,(1,.89,.76))
area('Rim strip',(.05,.22,.32),4,.20,(.75,.84,1))
camdata=bpy.data.cameras.new('XM4 Camera');cam=bpy.data.objects.new('XM4 Camera',camdata);studio.objects.link(cam)
cam.location=(.34,-.46,.27);target=Vector((0,0,.108));cam.rotation_euler=(target-cam.location).to_track_quat('-Z','Y').to_euler()
camdata.type='ORTHO';camdata.ortho_scale=.275;scene.camera=cam
scene.render.engine='CYCLES';scene.cycles.samples=32
scene.cycles.use_denoising=True
scene.render.resolution_x=1100;scene.render.resolution_y=1100;scene.render.resolution_percentage=100
scene.render.image_settings.file_format='PNG';scene.render.film_transparent=True
scene.view_settings.view_transform='AgX'
# Keep a useful material-preview viewport in the editable source.
for screen in bpy.data.screens:
    for ar in screen.areas:
        if ar.type=='VIEW_3D':
            ar.spaces.active.region_3d.view_distance=.4
            ar.spaces.active.region_3d.view_location=(0,0,.108)
            ar.spaces.active.clip_start=.001
            ar.spaces.active.shading.type='MATERIAL'
# Convert lettering to geometry: the source and runtime files contain no font files.
for ob in list(model.objects):
    if ob.type == 'FONT':
        for selected in bpy.context.selected_objects:
            selected.select_set(False)
        ob.select_set(True)
        bpy.context.view_layer.objects.active = ob
        bpy.ops.object.convert(target='MESH')
# Save only this scene and its dependencies, excluding unrelated open Blender work.
bpy.context.view_layer.update()
bpy.data.libraries.write(str(ROOT/'artwork/WH-1000XM4.blend'), {scene},
                         path_remap='RELATIVE', fake_user=True, compress=True)
for ob in scene.objects:ob.select_set(False)
for ob in model.objects:ob.select_set(True)
bpy.ops.wm.usd_export(filepath=str(OUT/'WH-1000XM4.usdz'),selected_objects_only=True,export_animation=False,export_lights=False,export_cameras=False,export_materials=True,generate_preview_surface=True,generate_materialx_network=False,convert_orientation=True,export_global_forward_selection='NEGATIVE_Z',export_global_up_selection='Y',export_textures_mode='NEW',overwrite_textures=True)
scene.render.filepath=str(OUT/'WH-1000XM4.png')
bpy.ops.render.render(write_still=True)
result={'objects':len(model.objects),'vertices':sum(len(o.data.vertices) for o in model.objects if o.type=='MESH'),'blend':str(ROOT/'artwork/WH-1000XM4.blend'),'usdz':str(OUT/'WH-1000XM4.usdz')}
