import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from desktop_observation import _model_state,validate_observation,FEISHU,WECHAT
class ProjectionTests(unittest.TestCase):
 def setUp(self):
  self.composer={'element_id':'own-composer','role':'AXTextArea','value':'中文完整值'*1000,'value_complete':True}
  self.state={'target_pid':17,'elements':[{'role':'AXWindow','depth':0}]+[{'element_id':'button-'+str(i),'role':'AXButton'} for i in range(120)]+[self.composer], 'truncated':False}
  self.semantics={'recipient_verified':True,'composer':{'element_id':'own-composer','value_complete':True,'value':self.composer['value']}}
 def test_complete_composer_survives_control_budget(self):
  p=_model_state(FEISHU,self.state,self.semantics,False)
  self.assertIn(self.composer,p['elements']);self.assertEqual(self.composer['value'],'中文完整值'*1000)
  self.assertEqual(len(p['elements']),80);self.assertTrue(p['model_state_projection']['controls_truncated'])
  self.assertFalse(p['model_state_projection']['full_ax_tree_included']);self.assertEqual(len(self.state['elements']),122)
 def test_explicit_raw_returns_unchanged_full_state(self):self.assertIs(_model_state(FEISHU,self.state,self.semantics,True),self.state)
 def test_unknown_recipient_preserves_native_context(self):self.assertIs(_model_state(FEISHU,self.state,{**self.semantics,'recipient_verified':False},False),self.state)
 def test_incomplete_composer_preserves_native_context(self):self.assertIs(_model_state(FEISHU,self.state,{'recipient_verified':True,'composer':{'value_complete':False}},False),self.state)
 def test_wechat_snapshot_is_not_projected(self):self.assertIs(_model_state(WECHAT,self.state,self.semantics,False),self.state)
 def test_raw_request_must_be_boolean(self):
  with self.assertRaises(ValueError):validate_observation({'app':FEISHU,'include_raw_state':'false'})
  validate_observation({'app':FEISHU,'include_raw_state':False})
