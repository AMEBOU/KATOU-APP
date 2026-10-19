const express = require('express');
const sqlite3 = require('sqlite3').verbose();
const bcrypt = require('bcrypt');
const jwt = require('jwt-simple');

const app = express();
const PORT = process.env.PORT || 3000;
const SECRET_KEY = process.env.JWT_SECRET || 'katou_secret_key_12345';

app.use(express.json());

// Base de données SQLite en mémoire / fichier local
const db = new sqlite3.Database('./katou.db', (err) => {
  if (err) {
    console.error('Erreur ouverture DB:', err.message);
  } else {
    console.log('Connecté à la base de données SQLite.');
  }
});

// Initialisation des tables
db.serialize(() => {
  db.run(`CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE,
    password TEXT,
    role TEXT
  )`);

  db.run(`CREATE TABLE IF NOT EXISTS tickets (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    hash TEXT UNIQUE,
    event_name TEXT,
    status TEXT DEFAULT 'VALID'
  )`);
});

// Route de test
app.get('/', (get, res) => {
  res.send('Serveur KATOU Backend opérationnel !');
});

// Route Connexion Admin / Agent
app.post('/api/auth/login', (req, res) => {
  const { username, password } = req.body;
  db.get('SELECT * FROM users WHERE username = ?', [username], (err, user) => {
    if (err || !user) {
      return res.status(401).json({ error: 'Utilisateur introuvable' });
    }
    const valid = bcrypt.compareSync(password, user.password);
    if (!valid) {
      return res.status(401).json({ error: 'Mot de passe incorrect' });
    }
    const token = jwt.encode({ id: user.id, username: user.username, role: user.role }, SECRET_KEY);
    res.json({ token, role: user.role });
  });
});

// Route Scan Ticket
app.post('/api/tickets/scan', (req, res) => {
  const { hash } = req.body;
  if (!hash) {
    return res.status(400).json({ error: 'Hash manquant' });
  }

  db.get('SELECT * FROM tickets WHERE hash = ?', [hash], (err, ticket) => {
    if (err || !ticket) {
      return res.status(404).json({ status: 'INVALID', message: 'Ticket introuvable' });
    }
    if (ticket.status === 'USED') {
      return res.status(400).json({ status: 'ALREADY_USED', message: 'Ticket déjà composté' });
    }

    db.run('UPDATE tickets SET status = ? WHERE id = ?', ['USED', ticket.id], function (err) {
      if (err) {
        return res.status(500).json({ error: 'Erreur mise à jour ticket' });
      }
      res.json({ status: 'VALID', message: 'Ticket validé avec succès', event: ticket.event_name });
    });
  });
});

app.listen(PORT, () => {
  console.log(`Serveur KATOU à l'écoute sur le port ${PORT}`);
});
