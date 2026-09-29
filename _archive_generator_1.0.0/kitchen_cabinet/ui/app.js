let state={params:{},id:null,cabinets:[],materials:[]};
const ids=['type','width','depth','height','placement_gap','panel_thickness','back_thickness','shutter_thickness','door_gap','shutter_distance','shelf_thickness','shelf_depth_reduction','shelf_position','shelf_count','opening_angle','door_material','show_opening_line','toe_kick_enabled','toe_kick_height','toe_kick_thickness','toe_kick_length','toe_kick_mode','toe_kick_material','carcass_material','show_carcass','show_doors','show_toe_kick','show_shelves','show_back'];
function $(id){return document.getElementById(id)}
function sketchupCall(name,arg){if(window.sketchup&&sketchup[name]) sketchup[name](arg)}
function collect(){let p={};ids.forEach(id=>{let e=$(id);if(!e)return;p[id]=(e.type==='checkbox'?e.checked:e.type==='number'?parseFloat(e.value||0):e.value)});return JSON.stringify(p)}
function fill(p){ids.forEach(id=>{let e=$(id);if(!e||p[id]===undefined)return;if(e.type==='checkbox')e.checked=!!p[id];else e.value=p[id]});}
function materials(){['carcass_material','door_material','toe_kick_material'].forEach(id=>{let e=$(id), old=e.value;e.innerHTML='<option value="">Default</option>'+state.materials.map(m=>`<option>${esc(m)}</option>`).join('');if(state.params[id])e.value=state.params[id];else e.value=old})}
function esc(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
window.loadCabinet=function(payload){state=payload||state;fill(state.params||{});materials();$('active').textContent=state.id||'No cabinet selected';let list=$('cabinet_list');list.innerHTML='';state.cabinets.forEach(c=>{let o=document.createElement('option');o.value=c.id;o.textContent=`${c.id} — ${c.params.width} × ${c.params.depth} × ${c.params.height}`;if(c.id===state.id)o.selected=true;list.appendChild(o)});}
window.selectionCleared=function(){$('active').textContent='No cabinet selected'};
function insertCabinet(){sketchup.insert(collect())}
function updateCabinet(){sketchup.update(collect())}
function selectCabinet(){let v=$('cabinet_list').value;if(v)sketchup.select(v)}
ids.forEach(id=>{document.addEventListener('change',e=>{if(e.target&&e.target.id===id&&state.id)sketchup.update(collect())})});
window.addEventListener('load',()=>{sketchup.ready()});
