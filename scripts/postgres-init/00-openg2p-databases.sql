-- Shared roles and databases for OpenG2P local development.
-- Runs once on first Postgres container start.

-- Odoo shared role (PBMS native dev)
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'odoo') THEN
    CREATE ROLE odoo WITH LOGIN PASSWORD 'odoo' CREATEDB;
  END IF;
END
$$;

-- PBMS
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pbmsuser') THEN
    CREATE ROLE pbmsuser WITH LOGIN PASSWORD 'pbmspass' CREATEDB;
  END IF;
END
$$;

SELECT 'CREATE DATABASE pbmsdb OWNER pbmsuser'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'pbmsdb')\gexec

-- PBMS background tasks (eligibility / entitlement engine state)
SELECT 'CREATE DATABASE bgtaskdb OWNER postgres'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'bgtaskdb')\gexec

-- Registry Gen2: Farmer Registry
SELECT 'CREATE DATABASE farmer_registry_db OWNER postgres'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'farmer_registry_db')\gexec

SELECT 'CREATE DATABASE farmer_master_data_db OWNER postgres'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'farmer_master_data_db')\gexec

-- Registry Gen2: National Social Registry
SELECT 'CREATE DATABASE nsr_registry_db OWNER postgres'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'nsr_registry_db')\gexec

SELECT 'CREATE DATABASE nsr_master_data_db OWNER postgres'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'nsr_master_data_db')\gexec

-- G2P Bridge
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'bridgeuser') THEN
    CREATE ROLE bridgeuser WITH LOGIN PASSWORD 'bridgepass' CREATEDB;
  END IF;
END
$$;

SELECT 'CREATE DATABASE g2pbridgedb OWNER bridgeuser'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'g2pbridgedb')\gexec

SELECT 'CREATE DATABASE examplebankdb OWNER bridgeuser'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'examplebankdb')\gexec

-- SPAR
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'sparuser') THEN
    CREATE ROLE sparuser WITH LOGIN PASSWORD 'password' CREATEDB;
  END IF;
END
$$;

SELECT 'CREATE DATABASE spardb OWNER sparuser'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'spardb')\gexec

-- IAM Staff Portal API
SELECT 'CREATE DATABASE iam_staff OWNER postgres'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'iam_staff')\gexec

-- Approval Workflow Engine (AWE)
SELECT 'CREATE DATABASE awe OWNER postgres'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'awe')\gexec

-- OpenG2P ID Generator (functional / registry IDs)
SELECT 'CREATE DATABASE idgenerator OWNER postgres'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'idgenerator')\gexec

-- Required for registry search indexes during Alembic migration
\c nsr_registry_db
CREATE EXTENSION IF NOT EXISTS pg_trgm;

\c farmer_registry_db
CREATE EXTENSION IF NOT EXISTS pg_trgm;

\c awe
CREATE EXTENSION IF NOT EXISTS pg_trgm;
