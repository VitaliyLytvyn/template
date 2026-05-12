CREATE DATABASE IF NOT EXISTS appdb;
USE appdb;

CREATE TABLE IF NOT EXISTS items (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  description TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

INSERT INTO items (name, description) VALUES
   ('Sample Item 1', 'This is the first sample item'),
   ('Sample Item 2', 'This is the second sample item'),
   ('Sample Item 3', 'This is the third sample item'),
   ('Sample Item 4', 'This is the fourth sample item'),
   ('Sample Item 5', 'This is the fifth sample item'),
   ('Sample Item 6', 'This is the sixth sample item'),
   ('Sample Item 7', 'This is the seventh sample item');
