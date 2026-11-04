#!/usr/bin/env python3
"""Run the pinned upstream visits schema in SQLite; no custom allocator."""
import ast
import re
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PIN = 'd0c02bfad08ec92a6ffcf989e53cd995e6381a4c'
SOURCE = Path('/Users/takamimarsh/Developer/zacro-chromium/chromium/src')
TEXT = subprocess.check_output(['git', 'show', PIN + ':components/history/core/browser/visit_database.cc'], cwd=SOURCE, text=True)
CREATE = TEXT.split('"CREATE TABLE visits("', 1)[1].split('))', 1)[0]
CREATE = re.sub(r'//[^\n]*', '', CREATE)
SCHEMA = 'CREATE TABLE visits(' + ''.join(ast.literal_eval(s) for s in re.findall(r'"(?:\\.|[^"\\])*"', CREATE))

class NativeVisitIdentitySQLTests(unittest.TestCase):
    def insert(self, db):
        return db.execute('INSERT INTO visits(url,visit_time) VALUES(1,1700000000)').lastrowid

    def test_actual_pinned_schema_already_uses_autoincrement(self):
        self.assertIn('id INTEGER PRIMARY KEY AUTOINCREMENT', SCHEMA)
        db = sqlite3.connect(':memory:'); db.execute(SCHEMA)
        self.assertIn('AUTOINCREMENT', db.execute("SELECT sql FROM sqlite_master WHERE name='visits'").fetchone()[0])

    def test_highest_delete_exact_historical_time_reimport_never_reuses_after_restart(self):
        with tempfile.TemporaryDirectory() as root:
            path = str(Path(root) / 'History')
            db = sqlite3.connect(path); db.execute(SCHEMA)
            first = self.insert(db); highest = self.insert(db); db.commit()
            db.execute('DELETE FROM visits WHERE id=?', (highest,)); db.commit(); db.close()
            db = sqlite3.connect(path); replacement = self.insert(db)
            self.assertGreater(replacement, highest)
            self.assertEqual([(first,), (replacement,)], db.execute('SELECT id FROM visits ORDER BY id').fetchall())
            self.assertEqual([1700000000, 1700000000], [r[0] for r in db.execute('SELECT visit_time FROM visits')])
            db.close()

    def test_rollback_can_reuse_only_uncommitted_identity(self):
        db = sqlite3.connect(':memory:'); db.execute(SCHEMA)
        committed = self.insert(db); db.commit()
        uncommitted = self.insert(db); db.rollback()
        self.assertEqual(uncommitted, self.insert(db)); self.assertGreater(uncommitted, committed)

    def test_table_reset_can_reuse_id_and_therefore_needs_separate_native_epoch(self):
        db = sqlite3.connect(':memory:'); db.execute(SCHEMA)
        original = self.insert(db); db.commit()
        db.execute('DROP TABLE visits'); db.execute(SCHEMA)
        self.assertEqual(original, self.insert(db))
        # The actual native HistoryDatabase test independently checks that the
        # reset generation advances atomically with this table recreation.

    def test_old_schema_migration_also_restores_autoincrement(self):
        migration = TEXT.split('bool VisitDatabase::MigrateVisitsAutoincrementIdAndAddOriginatorColumns()', 1)[1]
        migration = migration.split('bool VisitDatabase::MigrateVisitsAddOriginatorFromVisitAndOpenerVisitColumns()', 1)[0]
        self.assertIn('VisitTableContainsAutoincrement()', migration)
        self.assertIn('"id INTEGER PRIMARY KEY AUTOINCREMENT,"', migration)

if __name__ == '__main__':
    unittest.main()
