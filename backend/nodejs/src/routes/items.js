const express = require('express');
const router = express.Router();
const pool = require('../db');

router.get('/', (req, res) => {
  pool.query('SELECT * FROM items ORDER BY created_at DESC', (err, results) => {
    if (err) return res.status(500).json({ error: err.message });
    res.json(results);
  });
});

router.get('/:id', (req, res) => {
  pool.query('SELECT * FROM items WHERE id = ?', [req.params.id], (err, results) => {
    if (err) return res.status(500).json({ error: err.message });
    if (results.length === 0) return res.status(404).json({ error: 'Item not found' });
    res.json(results[0]);
  });
});

router.post('/', (req, res) => {
  const { name, description } = req.body;
  if (!name) return res.status(400).json({ error: 'Name is required' });

  pool.query(
    'INSERT INTO items (name, description) VALUES (?, ?)',
    [name, description || ''],
    (err, results) => {
      if (err) return res.status(500).json({ error: err.message });
      res.status(201).json({ id: results.insertId, name, description: description || '' });
    }
  );
});

router.put('/:id', (req, res) => {
  const { name, description } = req.body;
  if (!name) return res.status(400).json({ error: 'Name is required' });

  pool.query(
    'UPDATE items SET name = ?, description = ? WHERE id = ?',
    [name, description || '', req.params.id],
    (err, results) => {
      if (err) return res.status(500).json({ error: err.message });
      if (results.affectedRows === 0) return res.status(404).json({ error: 'Item not found' });
      res.json({ id: parseInt(req.params.id), name, description: description || '' });
    }
  );
});

router.delete('/:id', (req, res) => {
  pool.query('DELETE FROM items WHERE id = ?', [req.params.id], (err, results) => {
    if (err) return res.status(500).json({ error: err.message });
    if (results.affectedRows === 0) return res.status(404).json({ error: 'Item not found' });
    res.json({ message: 'Item deleted' });
  });
});

module.exports = router;
