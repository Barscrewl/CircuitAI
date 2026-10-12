import unittest
from sea_arena import scenario_label, frozen_actor_condition, audit_transit


class ScenarioLabelTests(unittest.TestCase):
    def test_transit_ignores_non_state_boat_messages(self):
        case={'groups':[{'team':0,'unit':'armroy','count':1}],
              'native_transit':{'unit':'armroy','points':[[10,20]]}}
        text=(' [SeaArena] frame=3000 boat id=2 unit=armroy x=10 z=20 health=100 maxhealth=100 queue=0\n'
              ' [SeaArena] frame=3001 boat id=2 unit=armroy x=10 z=20 health=100\n')
        self.assertEqual(audit_transit(text,case),[])
    def test_repair_fixture_freezes_production_not_static_assistance(self):
        self.assertEqual(frozen_actor_condition('factory',True), 'SeaEconomy::SupportedFactory(u.circuitDef)')
        self.assertIn('ConstructorDef', frozen_actor_condition('builder',True))
        self.assertEqual(frozen_actor_condition('factory',False), 'ai.frame>=0')
    def test_existing_short_categories_are_unchanged(self):
        self.assertEqual(scenario_label('surface-line'), 'surface-line-cand')

    def test_long_related_cases_do_not_collapse(self):
        names = [scenario_label('legion-submarine-'+end, control)
                 for end in ('supported', 'unsupported') for control in (True, False)]
        self.assertEqual(len(set(names)), 4)
        self.assertTrue(all(len(name)<=24 for name in names))


if __name__ == '__main__':
    unittest.main()
