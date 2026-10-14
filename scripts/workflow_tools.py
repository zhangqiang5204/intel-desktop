"""Task queue and registered desktop-plan integration for the stdio MCP owner."""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
from desktop_transactions import TRANSACTION_TOOL,execute_transaction,validate_plan
from learning_store import LearningStore
from task_runtime import TaskRuntime,current_context,COMPLETION_PURPOSES

RUNTIME_PROPERTIES={
 'task_id':{'type':'string','minLength':1,'maxLength':96,'description':'Stable opaque current-thread/workflow ID. Reuse across its calls; it is correlation, never action authorization.'},
 'operation_id':{'type':'string','minLength':1,'maxLength':96,'description':'Unique logical invocation ID. Repeated IDs never replay; uncertain outcomes need fresh observation.'},
 'transaction_id':{'type':'string','minLength':1,'maxLength':96,'description':'Causal transaction grouping ID; never grants send or rollback authority.'},
 'queue_timeout_ms':{'type':'integer','minimum':0,'maximum':120000,'description':'Maximum wait before execution. Expired unstarted calls perform no input.'}}
TASK_TOOL={'name':'desktop_task','description':'Inspect metadata-only queue and execution logs, cancel this caller task at a safe boundary, or record a completion span from explicitly named same-task terminal operations and a real verified end source. Completion only records timestamps/outcomes; it grants no action authority and never executes or replays input.',
 'inputSchema':{'type':'object','properties':{'action':{'type':'string','enum':['queue','logs','operation','cancel','complete']},'target_operation_id':{'type':'string'},'after':{'type':'integer','minimum':0},'limit':{'type':'integer','minimum':1,'maximum':200},'unit_id':{'type':'string','minLength':1,'maxLength':128},'purpose':{'type':'string','enum':sorted(COMPLETION_PURPOSES)},'operation_ids':{'type':'array','minItems':1,'maxItems':128,'uniqueItems':True,'items':{'type':'string'}},'verified_operation_id':{'type':'string'}},'required':['action'],'additionalProperties':False},'annotations':{'readOnlyHint':False,'openWorldHint':False}}
SCRIPT_TOOL={'name':'desktop_script','description':'Collect a registered local model script as a candidate, or execute its current-digest parameterized desktop_plan/v1 through one queued transaction and complete real postconditions. Arbitrary Python/Swift/shell candidates are never imported or executed from statistics. No retained message-send authorization, automatic rollback or replay.',
 'inputSchema':{'type':'object','properties':{'action':{'type':'string','enum':['register','list','run','analyze']},'app':{'type':'string'},'source_path':{'type':'string'},'parameter_names':{'type':'array','maxItems':32,'items':{'type':'string'}},'purpose':{'type':'string'},'script_id':{'type':'string'},'parameters':{'type':'object'}},'required':['action'],'additionalProperties':False},'annotations':{'readOnlyHint':False,'openWorldHint':False}}

def add_runtime_schema(tools):
 for tool in tools:
  schema=tool['inputSchema'];schema['properties']={**schema['properties'],**RUNTIME_PROPERTIES}

def runtime_arguments(arguments,runtime):
 if not isinstance(arguments,dict):raise ValueError('Tool arguments must be an object')
 args=dict(arguments);meta={k:args.pop(k) for k in RUNTIME_PROPERTIES if k in args}
 meta['task_id']=meta.get('task_id',runtime.session_id)
 timeout=meta.pop('queue_timeout_ms',30000)
 if type(timeout)is not int or not 0<=timeout<=120000:raise ValueError('Queue timeout must be 0..120000 ms')
 meta['wait_timeout']=timeout/1000
 return args,meta

def classify_result(command,args,response,context):
 lifecycle=response.get('focus_lifecycle')
 if lifecycle in {'restored','yielded_to_user','unverified'}:
  metadata={k:response[k] for k in ('focus_return_required','focus_claim_verified','focus_restore_requested','business_completed','scope_completed') if type(response.get(k)) is bool}
  metadata.update(focus_restored=lifecycle=='restored',focus_yielded_to_user=lifecycle=='yielded_to_user',focus_return_unverified=lifecycle=='unverified')
  context.record_phase('postcondition','focus_lifecycle',verified_flags=metadata)
 if context._outcome is not None:return
 if not response.get('ok'):
  error=response.get('error',{});code=error.get('code','operation_failed');details=error.get('details',{})
  uncertain=(response.get('completion_unknown') is True or details.get('input_may_be_partial') is True
             or code in {'native_transport_error','native_protocol_error','background_postcondition_unknown','transaction_postcondition_failed'})
  state='unknown' if uncertain else ('interrupted' if code in {'user_interrupted','task_cancelled','runtime_cancelled'} else 'failed')
  context.set_outcome(state,error_code=code);return
 value=response.get('result',{});flags={}
 if command=='chat' and args.get('action') in {'draft','clear'} and value.get('draft_verified') is True and value.get('recipient_verified') is True:
  focus=value.get('foreground_preserved') is True or value.get('focus_isolated') is True or value.get('focus_restored') is True
  flags={'proof_full_value':True,'proof_same_target':True,'focus_verified':focus,'draft_verified':True,'recipient_verified':True}
 elif (command=='chat' and args.get('action')=='send' and response.get('ok') is True
       and value.get('sent') is True and value.get('send_verified') is True
       and value.get('submission_state')=='observed_in_chat' and value.get('draft_empty') is True
       and value.get('recipient_verified') is True
       and value.get('send_verification_source')=='fresh_same_chat_empty_composer_and_increased_complete_exact_text_row_occurrence'):
  focus=any(source.get(key) is True for source in (value,response)
            for key in ('foreground_preserved','focus_isolated','focus_restored','system_focus_preserved'))
  flags={'proof_full_value':True,'proof_same_target':True,'focus_verified':focus,'recipient_verified':True,'value_verified':True,'proof_chat_send':True}
 elif command in {'type_text','set_text','clear_text','background_type_text','background_chat_edit'} and value.get('value_verified') is True:
  flags={'proof_full_value':True,'proof_same_target':True,'focus_verified':True,'value_verified':True}
 elif command=='select_text' and response.get('ok') is True and value.get('selection_verified') is True and value.get('value_verified') is True and value.get('text_unchanged') is True and (value.get('system_focus_preserved') is True or value.get('foreground_verified') is True):
  flags={'proof_full_value':True,'proof_same_target':True,'focus_verified':True,'value_verified':True,'proof_text_selection':True}
 elif command in {'observe','inspect','status','wait_text','visual_read','background_visual_read','recipe'}:
  context.set_outcome('completed');return
 if flags:
  if lifecycle=='unverified':flags['focus_verified']=False
  elif lifecycle=='yielded_to_user':flags['focus_verified']=response.get('scope_completed') is True
  elif lifecycle=='restored':flags['focus_verified']=True
  elif any(source.get('focus_return_required') is True for source in (value,response)):
   flags['focus_verified']=any(source.get('focus_restored') is True for source in (value,response))
  context.record_phase('postcondition','complete_chat_send' if command=='chat' and args.get('action')=='send' else 'complete_native_value',verified_flags=flags)
  context.set_outcome('verified' if all(flags.values()) else 'accepted_unverified',verified_flags=flags)
 else:context.set_outcome('accepted_unverified')

def task_action(args,meta,runtime):
 if set(args)-set(TASK_TOOL['inputSchema']['properties']):raise ValueError('Unknown task argument')
 task=meta['task_id'];action=args.get('action');limit=args.get('limit',100)
 if type(limit)is not int or not 1<=limit<=200:raise ValueError('Task result bound required')
 if action=='queue':value=runtime.queue(task_id=task,limit=min(limit,100))
 elif action=='logs':value=runtime.logs(task_id=task,operation_id=args.get('target_operation_id'),after=args.get('after',0),limit=limit)
 elif action=='operation':
  value=runtime.get_operation(args.get('target_operation_id'))
  if value is not None and value.get('task_id')!=task:raise ValueError('Operation belongs to a different task')
 elif action=='cancel':value=runtime.cancel(task,args.get('target_operation_id'),requester_task_id=task)
 elif action=='complete':
  if set(args)!={'action','unit_id','purpose','operation_ids','verified_operation_id'}:raise ValueError('Completion accepts only fixed metadata identifiers and explicit operation references')
  value=runtime.record_task_completion(task,args['unit_id'],args['purpose'],args['operation_ids'],args['verified_operation_id'])
 else:raise ValueError('Unknown task action')
 return {'ok':True,'result':value,'task_id':task}

def script_action(args,dispatch,context,runtime):
 if set(args)-set(SCRIPT_TOOL['inputSchema']['properties']):raise ValueError('Unknown script argument')
 store=LearningStore(runtime.directory,runtime=runtime);action=args.get('action')
 if action=='register':
  row=store.register(context.task_id,args.get('app'),args.get('source_path'),args.get('parameter_names',[]),args.get('purpose','desktop_workflow'))
  return {'ok':True,'result':row}
 if action=='list':return {'ok':True,'result':store.list()}
 if action=='analyze':return {'ok':True,'result':store.analyze()}
 if action!='run':raise ValueError('Unknown script action')
 if not isinstance(args.get('app'),str):raise ValueError('Script execution requires its exact registered application')
 rows=store.list()['scripts'];row=next((r for r in rows if r['id']==args.get('script_id')),None)
 if row is None:raise ValueError('Registered script not found')
 if args.get('app') and args['app']!=row['app']:raise ValueError('Registered application changed')
 if row.get('format')!='desktop_plan/v1' or row.get('parameterization_candidate') is not True:raise ValueError('Source is a candidate requiring conversion/redaction, not an executable desktop plan')
 path=Path(row['source_path']);data=path.read_bytes()
 if len(data)>256*1024 or hashlib.sha256(data).hexdigest()!=row['source_sha256']:raise ValueError('Registered current source digest changed')
 plan=json.loads(data)
 if plan.get('app')!=row['app'] or sorted(plan.get('parameter_names',[]))!=sorted(row['parameter_names']):raise ValueError('Registered target or parameter declaration changed')
 params=args.get('parameters',{})
 if not isinstance(params,dict) or set(params)!=set(row['parameter_names']):raise ValueError('Provide exactly the registered parameter names')
 if 'parameters' in plan:raise ValueError('Registered plans cannot retain invocation parameter values')
 validate_plan(plan)
 digest=hashlib.sha256(json.dumps(plan,sort_keys=True,separators=(',',':')).encode()).hexdigest()
 context.record_source(row['id'],row['source_sha256'],plan_digest=digest,parameter_names=row['parameter_names'])
 runtime.bind_application(context.operation_id,row['app']) if hasattr(runtime,'bind_application') else None
 response=execute_transaction({**plan,'parameters':params},dispatch,context)
 response['script_id']=row['id'];return response

def after_script_result(response,runtime):
 if response.get('script_id') and response.get('operation_id'):
  try:response['learning']=LearningStore(runtime.directory,runtime=runtime).record_verified_execution(response['script_id'],response['operation_id'])
  except (ValueError,OSError):response['learning_recorded']=False
