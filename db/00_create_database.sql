IF DB_ID('DispatchDB') IS NULL CREATE DATABASE DispatchDB;
GO
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name='dispatch_app')
  CREATE LOGIN dispatch_app WITH PASSWORD = N'CHANGE_ME_APP', CHECK_POLICY = OFF;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name='dispatch_admin')
  CREATE LOGIN dispatch_admin WITH PASSWORD = N'CHANGE_ME_ADMIN', CHECK_POLICY = OFF;
GO
USE DispatchDB;
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name='dispatch_app') CREATE USER dispatch_app FOR LOGIN dispatch_app;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name='dispatch_admin') CREATE USER dispatch_admin FOR LOGIN dispatch_admin;
ALTER ROLE db_owner ADD MEMBER dispatch_admin;
ALTER ROLE db_datareader ADD MEMBER dispatch_app;
ALTER ROLE db_datawriter ADD MEMBER dispatch_app;
GRANT EXECUTE TO dispatch_app;
GO
