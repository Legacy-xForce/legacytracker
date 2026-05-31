import { Pool } from 'pg';

const connectionString = process.env.DATABASE_URL || 'postgres://localhost:5432/legacytracker';

const pool = new Pool({
  connectionString,
  max: 10,
});

export default pool;
