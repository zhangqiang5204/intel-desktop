"""Bounded desktop plans. No eval, shell execution, replay or guessed rollback."""
from __future__ import annotations
import json
import math
import re
import time

ALLOWED = {'status','inspect','focus','press','click','set_text','select_text','type_text','clear_text','key',
           'scroll','wait_text','batch','visual_read','visual_click','visual_type_text','visual_key',
           'visual_scroll','background_visual_read','background_type_text','background_chat_edit','chat','observe'}
READS = {'inspect','visual_read','background_visual_read','observe'}
SELECTOR_FIELDS = {'role','title','description','identifier','subrole','menu_path','parent','ancestor'}
CHAT_RECEIPT_VALUES = {'/result/focus_isolated':True,'/result/focus_attempted':False,
 '/result/activated_foreground':False,'/result/recipient_verified':True,
 '/result/draft_verified':True,'/result/sent':False,'/result/automatic_replay_allowed':False}
SELECTION_RECEIPT_VALUES = {'/result/selection_verified':True,'/result/value_verified':True,
 '/result/text_unchanged':True,'/result/system_focus_preserved':True,'/result/events_posted':0}
SELECTION_RANGE_PATHS = {'/result/'+range_name+'/'+field for range_name in ('selection','previous_selection') for field in ('location','length')}
ELEMENT_RANGE_ATTRIBUTES = {'selected_range/location','selected_range/length'}
TRANSACTION_TOOL = {
 'name':'desktop_transaction',
 'description':'Execute a bounded single-app desktop workflow under one cross-session queue claim. Bind controls only to this invocation, verify explicit fresh full-value postconditions and stop on failure/cancel/unknown outcome. This is a causal execution transaction, without rollback of user state or automatic replay. Never embeds old send authorization.',
 'inputSchema':{'type':'object','properties':{
  'app':{'type':'string'},'window_title':{'type':'string'},
  'steps':{'type':'array','minItems':1,'maxItems':16,'items':{'type':'object','properties':{'id':{'type':'string'},'tool':{'type':'string','enum':sorted(ALLOWED)},'arguments':{'type':'object'}},'required':['id','tool','arguments'],'additionalProperties':False}},
  'postconditions':{'type':'array','minItems':1,'maxItems':16,'items':{'type':'object','description':'Checks run immediately after their declared step, before later input. Use a fresh read path or unique complete nonsecure AX value/selected_range field with an exact selector. Background draft/clear chat and background select_text steps may assert only fixed safe receipt flags; select_text also allows exact selection/previous_selection location/length checks. A final fresh complete value read is still required. Bind parameters using {"$param":"name"}.'}},
  'parameters':{'type':'object'},
 },'required':['app','steps','postconditions'],'additionalProperties':False},
 'annotations':{'readOnlyHint':False,'destructiveHint':False,'openWorldHint':False}}

def pointer(value,path):
 if not isinstance(path,str) or not path.startswith('/') or len(path)>512:raise ValueError('A bounded JSON pointer is required')
 for part in path[1:].split('/'):
  part=part.replace('~1','/').replace('~0','~')
  if isinstance(value,list):
   if not part.isdigit():raise ValueError('Invalid list pointer')
   index=int(part)
   if index>=len(value):raise ValueError('Result pointer is absent')
   value=value[index]
  elif isinstance(value,dict):
   if part not in value:raise ValueError('Result pointer is absent')
   value=value[part]
  else:raise ValueError('Pointer does not identify a result')
 return value

def _selector_schema(selector,*,parameters=False,depth=0):
 if (not isinstance(selector,dict) or set(selector)-SELECTOR_FIELDS or 'role' not in selector
     or depth>6):raise ValueError('Bounded exact element selector required')
 def text(value,empty=False):
  return (isinstance(value,str) and len(value)<=1024 and (empty or bool(value))
          or parameters and isinstance(value,dict) and set(value)=={'$param'}
          and isinstance(value['$param'],str) and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]{0,63}',value['$param']))
 for key,value in selector.items():
  if key in {'parent','ancestor'}:_selector_schema(value,parameters=parameters,depth=depth+1)
  elif key=='menu_path':
   if not isinstance(value,list) or not 1<=len(value)<=16 or not all(text(part) for part in value):raise ValueError('Exact bounded menu path required')
  elif not text(value,empty=key in {'title','description'}):raise ValueError('Selector fields require exact bounded text')

def _inspect_elements(response):
 result=response.get('result',{})
 if response.get('ok') is not True or result.get('truncated') is not False:raise ValueError('Complete scoped native inspection required')
 elements=result.get('elements')
 menus=result.get('menu_elements',[])
 if (not isinstance(elements,list) or not isinstance(menus,list) or len(elements)+len(menus)>2000
     or any(not isinstance(e,dict) or not isinstance(e.get('element_id'),str) or not e['element_id'] for e in elements+menus)):
  raise ValueError('Complete current native element identities required')
 identities=[e['element_id'] for e in elements+menus]
 if len(set(identities))!=len(identities):raise ValueError('Current native element identities are ambiguous')
 return elements+menus,{e['element_id'] for e in menus}

def _safe_element(element,*,for_input=False):
 if element.get('secure') is not False or 'Secure' in str(element.get('role','')) or 'Secure' in str(element.get('subrole','')):
  raise ValueError('A protected or unverified control cannot be selected')
 if for_input and element.get('enabled') is False:raise ValueError('A disabled control cannot authorize input')

def _parents(element,by_id):
 ancestors=[];seen={element['element_id']};parent=element.get('parent_id')
 while parent is not None:
  if not isinstance(parent,str) or parent not in by_id or parent in seen:raise ValueError('Complete acyclic native parent identity required')
  seen.add(parent);element=by_id[parent];ancestors.append(element);parent=element.get('parent_id')
 return ancestors

def _element_target(response,item,elements,menu_ids,target):
 if target is None:return
 result=response['result']
 if result.get('app')!=target['app']:raise ValueError('Element binding target application changed')
 title=target.get('window_title')
 if not title:return
 roots=[e for e in elements if e.get('role')=='AXWindow' and e.get('depth')==0]
 if roots and len([e for e in roots if e.get('title')==title])!=1:raise ValueError('Element binding target window is absent or ambiguous')
 chain=[item,*_parents(item,{e['element_id']:e for e in elements})]
 windows=[e for e in chain if e.get('role')=='AXWindow' and e.get('depth')==0]
 if item['element_id'] in menu_ids:
  if roots and (len(roots)!=1 or roots[0].get('title')!=title):raise ValueError('Menu binding window identity is absent or ambiguous')
 elif roots and (len(windows)!=1 or windows[0].get('title')!=title):raise ValueError('Element binding crosses its target window')
 if not roots and actual_window_title(result)!=title:raise ValueError('Element binding window identity is absent or changed')

def select_element(response,selector,*,for_input=False,target=None):
 _selector_schema(selector)
 elements,menu_ids=_inspect_elements(response)
 by_id={e['element_id']:e for e in elements}
 scopes={key:select_element(response,selector[key],target=target) for key in ('parent','ancestor') if key in selector}
 def matches(element):
  if not all(element.get(key)==value for key,value in selector.items() if key not in {'parent','ancestor'}):return False
  if 'parent' in scopes and element.get('parent_id')!=scopes['parent']['element_id']:return False
  if 'ancestor' in scopes and not any(p['element_id']==scopes['ancestor']['element_id'] for p in _parents(element,by_id)):return False
  return True
 found=[e for e in elements if matches(e)]
 if len(found)!=1:raise ValueError('Current element is absent or ambiguous')
 item=found[0];_safe_element(item,for_input=for_input)
 result=response['result']
 if item['element_id'] in menu_ids and (result.get('menus_available') is not True or result.get('menus_truncated') is not False):
  raise ValueError('Complete current native menu inspection required')
 _element_target(response,item,elements,menu_ids,target)
 return item

def resolve(value,results,parameters,*,tools=None,target=None,for_input=False):
 if isinstance(value,dict):
  if set(value)=={'$param'}:
   name=value['$param']
   if not isinstance(name,str) or name not in parameters:raise ValueError('Required plan parameter missing')
   item=parameters[name]
   if isinstance(item,(dict,list)) or item is None:raise ValueError('Plan parameters must be scalar values')
   return item
  if set(value)=={'$ref'}:
   ref=value['$ref']
   if not isinstance(ref,str) or '/' not in ref:raise ValueError('Result reference must identify a previous step')
   step,path=ref.split('/',1)
   if path.endswith('/element_id'):
    if tools is not None and tools.get(step)!='inspect':raise ValueError('Element bindings require a prior inspect step')
    parent=pointer(results[step],'/'+path.rsplit('/',1)[0])
    if not isinstance(parent,dict):raise ValueError('A result reference must identify a current native control')
    elements,menu_ids=_inspect_elements(results[step])
    if parent not in elements:raise ValueError('Element reference is outside the current native inspection')
    _safe_element(parent,for_input=for_input)
    _element_target(results[step],parent,elements,menu_ids,target)
    r=results[step]['result']
    if parent['element_id'] in menu_ids and (r.get('menus_available') is not True or r.get('menus_truncated') is not False):raise ValueError('Complete current native menu inspection required')
   return pointer(results[step],'/'+path)
  if set(value)=={'$element'}:
   spec=value['$element']
   if not isinstance(spec,dict) or 'step' not in spec:raise ValueError('Element binding requires a previous inspect step')
   step=spec['step']
   if tools is not None and tools.get(step)!='inspect':raise ValueError('Element bindings require a prior inspect step')
   selector=resolve({k:v for k,v in spec.items() if k!='step'},results,parameters,tools=tools,target=target)
   item=select_element(results[step],selector,for_input=for_input,target=target)
   if not isinstance(item.get('element_id'),str):raise ValueError('Element binding is not current native identity')
   return item['element_id']
  if any(str(k).startswith('$') for k in value):raise ValueError('Unsupported plan binding')
  return {k:resolve(v,results,parameters,tools=tools,target=target,for_input=for_input) for k,v in value.items()}
 if isinstance(value,list):return [resolve(v,results,parameters,tools=tools,target=target,for_input=for_input) for v in value]
 return value

def validate_plan(plan):
 if not isinstance(plan,dict) or set(plan)-{'format','app','window_title','parameter_names','steps','postconditions','parameters'}:raise ValueError('Unknown desktop plan field')
 if plan.get('format','desktop_plan/v1')!='desktop_plan/v1':raise ValueError('Unknown desktop plan format')
 if not isinstance(plan.get('app'),str) or not re.fullmatch(r'[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+',plan['app']):raise ValueError('Exact application bundle ID required')
 if 'parameter_names' in plan:
  names=plan['parameter_names']
  if (not isinstance(names,list) or len(names)>32
      or any(not isinstance(name,str) or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]{0,63}',name) for name in names)
      or len(set(names))!=len(names)):
   raise ValueError('Unique bounded parameter names required')
 steps=plan.get('steps');checks=plan.get('postconditions')
 if not isinstance(steps,list) or not 1<=len(steps)<=16 or not isinstance(checks,list) or not 1<=len(checks)<=16:raise ValueError('Plan requires bounded steps and postconditions')
 ids=set()
 for step in steps:
  if not isinstance(step,dict) or set(step)!={'id','tool','arguments'} or not re.fullmatch(r'[a-zA-Z][a-zA-Z0-9_-]{0,63}',str(step.get('id',''))) or step['id'] in ids:raise ValueError('Unique bounded step ID required')
  ids.add(step['id'])
  if step['tool'] not in ALLOWED or not isinstance(step['arguments'],dict):raise ValueError('Unknown plan action')
  if step['tool']=='select_text' and step['arguments'].get('background') is not True:raise ValueError('Registered selection plans require literal background:true')
  if {'app','window_title','task_id','operation_id','transaction_id'} & set(step['arguments']):raise ValueError('Plan steps cannot override their target or task context')
  if step['tool']=='chat' and step['arguments'].get('action')=='send':raise ValueError('Registered plans cannot retain message-send authorization')
  if 'send_authorization' in step['arguments'] or step['arguments'].get('allow_submit'):raise ValueError('Send authorization must stay in the current human business call')
  if step['tool'] in {'key','visual_key'} and str(step['arguments'].get('key','')).lower() in {'return','enter'}:raise ValueError('Registered plans cannot replay Return')
 order={step['id']:i for i,step in enumerate(steps)}
 by_step={step['id']:step for step in steps}
 step_tools={step['id']:step['tool'] for step in steps}
 last_write=max((i for i,step in enumerate(steps) if step['tool'] not in READS|{'status','wait_text'}),default=-1)
 final_full_check=False
 for check in checks:
  if not isinstance(check,dict) or set(check)-{'step','path','element','attribute','equals'} or check.get('step') not in ids or 'equals' not in check:raise ValueError('Invalid plan postcondition')
  if ('path' in check)==('element' in check):raise ValueError('Choose a result path or an element value postcondition')
  if 'element' in check and check.get('attribute') not in {'value'}|ELEMENT_RANGE_ATTRIBUTES:raise ValueError('Element postconditions require a complete value or exact selected-range field')
  if 'element' in check:_selector_schema(check['element'],parameters=True)
  elif 'attribute' in check:raise ValueError('Path postconditions cannot declare an element attribute')
  if isinstance(check['equals'],dict) and set(check['equals'])!={'$param'}:raise ValueError('Expected outcomes must be literal values or caller parameters, not self-referenced observations')
  step=by_step[check['step']]
  if step['tool'] not in READS:
   args=step['arguments'];path=check.get('path')
   if step['tool']=='select_text':
    if path in SELECTION_RECEIPT_VALUES:
     expected=SELECTION_RECEIPT_VALUES[path]
     if type(check['equals'])is not type(expected) or check['equals']!=expected:raise ValueError('Selection receipts require fixed safe expected values')
    elif path in SELECTION_RANGE_PATHS:
     expected=check['equals']
     if not (type(expected)is int and 0<=expected<=131072 or isinstance(expected,dict) and set(expected)=={'$param'}):
      raise ValueError('Selection range checks require exact integer literals or caller parameters')
    else:raise ValueError('Selection receipts allow only fixed safety flags or exact current/previous selection fields')
   elif (step['tool']!='chat' or args.get('action') not in ('draft','clear') or args.get('background') is not True
         or path not in CHAT_RECEIPT_VALUES or type(check['equals'])is not bool or check['equals'] is not CHAT_RECEIPT_VALUES[path]):
    raise ValueError('Only fixed safe background draft/clear receipt flags may replace a read check')
  full=(check.get('attribute')=='value' or check.get('path') in {'/result/composer/value','/result/composer/draft'})
  final_full_check|=full and order[check['step']]>last_write
 if last_write>=0 and not final_full_check:raise ValueError('A complete value read after the last mutation is required')
 if len(json.dumps(plan,ensure_ascii=False).encode())>256*1024:raise ValueError('Plan exceeds 256 KiB')

def _preflight_value(value,previous,parameters):
 if isinstance(value,dict):
  if set(value)=={'$param'}:return resolve(value,{},parameters)
  if set(value)=={'$ref'}:
   ref=value['$ref'];step=ref.split('/',1)[0] if isinstance(ref,str) else ''
   if step not in previous or '/' not in ref:raise ValueError('Result bindings require a prior step')
   if ref.endswith('/element_id') and previous[step]!='inspect':raise ValueError('Element bindings require a prior inspect step')
   return value
  if set(value)=={'$element'}:
   spec=value['$element']
   if not isinstance(spec,dict) or spec.get('step') not in previous or previous[spec['step']]!='inspect':raise ValueError('Element bindings require a prior inspect step')
   selector={k:_preflight_value(v,previous,parameters) for k,v in spec.items() if k!='step'}
   _selector_schema(selector)
   return value
  if any(str(k).startswith('$') for k in value):raise ValueError('Unsupported plan binding')
  return {k:_preflight_value(v,previous,parameters) for k,v in value.items()}
 if isinstance(value,list):return [_preflight_value(v,previous,parameters) for v in value]
 return value

def _safe_action(tool,args,app,allowed_arguments,*,check_bindings=False,latest_allowed=False):
 if set(args)-allowed_arguments(tool):raise ValueError('Unknown desktop action argument')
 if 'debug_image_path' in args:raise ValueError('Registered workflows do not retain raw diagnostic captures')
 if check_bindings:
  for key,value in args.items():
   if key=='element_id' or key.endswith('_element_id') or key=='snapshot_id':
    binding=isinstance(value,dict) and set(value) in ({'$ref'},{'$element'})
    if not binding and not (key=='snapshot_id' and value=='latest' and latest_allowed):raise ValueError('Native identities must bind to a current read within this workflow')
    if key!='snapshot_id' and isinstance(value,dict) and '$ref' in value and not str(value['$ref']).endswith('/element_id'):
     raise ValueError('Element identity references must identify an actual current element_id')
 if args.get('allow_submit') or 'send_authorization' in args or tool=='submit_text' or tool=='chat' and args.get('action')=='send':raise ValueError('Registered workflows cannot retain send authority')
 if tool=='select_text':
  if args.get('background') is not True:raise ValueError('Registered selection plans require literal background:true')
  if 'text' in args and (not isinstance(args['text'],str) or not args['text']):raise ValueError('Exact nonempty selection text required before execution')
 if tool in {'key','visual_key'}:
  if not isinstance(args.get('key'),str):raise ValueError('Workflow keys must be known before execution')
  if args['key'].lower() in {'return','enter'}:raise ValueError('Registered workflows cannot replay Return')
 if tool=='type_text' and app in {'com.tencent.xinWeChat','com.bytedance.macos.feishu'} and isinstance(args.get('text'),str) and any(c in args['text'] for c in '\r\n'):raise ValueError('Chat workflow text cannot generate Return')
 if tool=='batch':
  actions=args.get('actions')
  if not isinstance(actions,list) or not 1<=len(actions)<=32:raise ValueError('Bounded known batch actions required')
  fresh_visual=False
  for child in actions:
   if not isinstance(child,dict) or child.get('command') not in ALLOWED or {'app','window_title'} & set(child):raise ValueError('Batch cannot override the workflow target')
   if child['command']=='select_text':raise ValueError('Background selection is a standalone workflow step, not a native batch action')
   _safe_action(child['command'],{k:v for k,v in child.items() if k!='command'},app,allowed_arguments,check_bindings=check_bindings,latest_allowed=fresh_visual)
   fresh_visual|=child['command']=='visual_read'

def preflight(plan,dispatch):
 parameters=plan.get('parameters',{})
 if not isinstance(parameters,dict) or len(parameters)>32:raise ValueError('Bounded plan parameters required')
 if any(isinstance(v,(dict,list)) or v is None for v in parameters.values()):raise ValueError('Plan parameters must be scalar values')
 if 'parameter_names' in plan and set(parameters)!=set(plan['parameter_names']):raise ValueError('Provide exactly the declared plan parameter names')
 allowed=getattr(dispatch,'allowed_arguments',None)
 if allowed is None:raise ValueError('The desktop owner must supply its actual action schema')
 title=_preflight_value(plan.get('window_title',''),{},parameters)
 if not isinstance(title,str):raise ValueError('Window target must be known before execution')
 previous={}
 for step in plan['steps']:
  args=_preflight_value(step['arguments'],previous,parameters)
  _safe_action(step['tool'],args,plan['app'],allowed,check_bindings=True)
  previous[step['id']]=step['tool']
 for check in plan['postconditions']:
  expected=_preflight_value(check['equals'],previous,parameters)
  if check.get('path') in SELECTION_RANGE_PATHS or check.get('attribute') in ELEMENT_RANGE_ATTRIBUTES:
   if type(expected)is not int or not 0<=expected<=131072:raise ValueError('Selection range checks require bounded integer caller values')
  if 'element' in check:
   selector=_preflight_value(check['element'],previous,parameters)
   _selector_schema(selector)

def actual_window_title(result):
 if isinstance(result.get('window_title'),str):return result['window_title']
 roots=[e for e in result.get('elements',[]) if e.get('role')=='AXWindow' and e.get('depth')==0 and isinstance(e.get('title'),str)]
 return roots[0]['title'] if len(roots)==1 else None

def _check_postcondition(check,response,tool,target,results,parameters):
 r=response.get('result',{})
 if tool not in READS:
  actual=pointer(response,check['path'])
 elif r.get('app')!=target['app']:raise ValueError('Postcondition target application changed')
 else:
  if 'element' in check:
   if tool!='inspect':raise ValueError('Element postconditions require complete native inspection')
   element=select_element(response,resolve(check['element'],results,parameters),target=target)
   complete=element.get('value_complete') is True or element.get('value_truncated') is False
   if ('value' not in element or not complete or element.get('value_truncated') is True or element.get('value_complete') is False):
    raise ValueError('Complete AX value unavailable')
   actual=element['value'] if check['attribute']=='value' else pointer(element,'/'+check['attribute'])
   if check['attribute'] in ELEMENT_RANGE_ATTRIBUTES and (type(actual)is not int or not 0<=actual<=131072):raise ValueError('Complete current AX selected range unavailable')
  else:
   if target.get('window_title') and actual_window_title(r)!=target['window_title']:raise ValueError('Actual postcondition window identity is absent or changed')
   actual=pointer(response,check['path'])
   if check['path'].startswith('/result/composer/') and r.get('composer',{}).get('value_complete') is not True:
    raise ValueError('Complete composer value unavailable')
 expected=resolve(check['equals'],results,parameters)
 return type(actual)==type(expected) and actual==expected, (check.get('attribute')=='value' or check.get('path') in {'/result/composer/value','/result/composer/draft'})

def _read_identity(result):
 # Observe keeps the native target binding in state. Visual snapshot/inspect
 # generations are per read; NativeObservation's generation changes only when
 # its PID/title/frame/topology/AX-window binding changes.
 state=result.get('state',{})
 if not isinstance(state,dict):state={}
 identity={}
 for key,aliases in {'pid':('target_pid','pid'),'window_id':('window_id','actual_main_window_id')}.items():
  for source in (result,state):
   value=next((source[name] for name in aliases if type(source.get(name))is int and source[name]>0),None)
   if value is not None:identity[key]=value;break
 for source in (result,state):
  if 'window_frame' in source and 'window_frame' not in identity:
   frame=source['window_frame']
   if (not isinstance(frame,dict) or any(type(frame.get(key))not in (int,float) or not -1_000_000<=frame[key]<=1_000_000
                                       or not math.isfinite(frame[key]) for key in ('x','y','width','height'))
       or frame['width']<=0 or frame['height']<=0):raise ValueError('Actual read target window geometry is unavailable')
   identity['window_frame']={key:frame[key] for key in ('x','y','width','height')}
  if 'display_topology_signature' in source and 'display_topology_signature' not in identity:
   topology=source['display_topology_signature']
   if not isinstance(topology,str) or not topology:raise ValueError('Actual read target display topology is unavailable')
   identity['display_topology_signature']=topology
 if (state.get('read_strategy')=='fresh_full_tree_batched_attributes'
     or state.get('observer_policy')=='advisory_invalidation_always_refetch_no_background_polling'):
  generation=state.get('generation')
  if type(generation)is not int or generation<0:raise ValueError('Actual native observation binding generation is unavailable')
  identity['native_observation_generation']=generation
 return identity

def execute_transaction(plan,dispatch,context=None):
 validate_plan(plan)
 preflight(plan,dispatch)
 parameters=plan.get('parameters',{})
 if not isinstance(parameters,dict) or len(parameters)>32:raise ValueError('Bounded plan parameters required')
 target={'app':plan['app']}
 if 'window_title' in plan:target['window_title']=resolve(plan['window_title'],{},parameters)
 results={};records=[];tools={};started=time.perf_counter();proof_full_value=False;mutation_completed=False;read_identity={};checks_passed=0
 try:
  for step in plan['steps']:
   if context:context.boundary()
   args={**({} if step['tool']=='status' else target),**resolve(step['arguments'],results,parameters,tools=tools,target=target,
                                                                for_input=step['tool'] not in READS|{'status','wait_text'})}
   _safe_action(step['tool'],{k:v for k,v in args.items() if k not in {'app','window_title'}},plan['app'],dispatch.allowed_arguments)
   if context:context.record_phase('executing','step:'+step['id'][:32]+':'+step['tool'])
   response=dispatch(step['tool'],args);results[step['id']]=response;tools[step['id']]=step['tool']
   records.append({'id':step['id'],'tool':step['tool'],'response':response})
   if not response.get('ok'):
    return {'ok':False,'error':response.get('error',{'code':'transaction_step_failed'}),'completion_unknown':mutation_completed,'result':{'steps':records,'completed_steps':len(records)-1,'failed_step':step['id'],'verified':False,'automatic_replay_allowed':False}}
   mutation_completed|=step['tool'] not in READS|{'status','wait_text','focus'}
   if step['tool'] in READS:
    identity=_read_identity(response.get('result',{}))
    if any(key not in identity for key in read_identity):raise ValueError('Actual read target PID/window identity became unavailable')
    if any(key in read_identity and read_identity[key]!=value for key,value in identity.items()):raise ValueError('Actual read target PID/window identity changed')
    read_identity.update(identity)
   for check in (item for item in plan['postconditions'] if item['step']==step['id']):
    passed,full=_check_postcondition(check,response,step['tool'],target,results,parameters)
    if not passed:
     return {'ok':False,'error':{'code':'transaction_postcondition_failed','message':'The actual complete value did not match its expected postcondition'},
             'completion_unknown':mutation_completed,'result':{'steps':records,'completed_steps':len(records),'failed_step':step['id'],
                                                             'verified':False,'automatic_replay_allowed':False}}
    checks_passed+=1;proof_full_value|=full
  flags={'proof_full_value':proof_full_value,'proof_same_target':True,'focus_verified':True,'postcondition_passed':True,'checks':checks_passed}
  if context:
   context.record_phase('postcondition','complete_value_check',verified_flags=flags)
   context.set_outcome('verified',verified_flags=flags)
  return {'ok':True,'elapsed_ms':round((time.perf_counter()-started)*1000,3),'result':{'steps':records,'completed_steps':len(records),'verified':True,'verification':flags,'automatic_replay_allowed':False}}
 except ValueError as error:
  # Never retain actual/expected content in an error or persisted diagnostic.
  return {'ok':False,'error':{'code':'transaction_invalid_binding','message':str(error)},'completion_unknown':mutation_completed,'result':{'steps':records,'completed_steps':len(records),'verified':False,'automatic_replay_allowed':False}}
