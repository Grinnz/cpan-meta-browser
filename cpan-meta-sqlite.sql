-- 1 up
CREATE TABLE IF NOT EXISTS "packages" (
  "package" TEXT NOT NULL PRIMARY KEY,
  "version" TEXT NULL,
  "path" TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS "perms" (
  "package" TEXT NOT NULL,
  "userid" TEXT NOT NULL,
  "best_permission" TEXT NOT NULL CHECK ("best_permission" IN ('m','f','c')),
  PRIMARY KEY ("package","userid")
);
CREATE INDEX IF NOT EXISTS "perms_userid_best_permission_idx" ON "perms" ("userid","best_permission");
CREATE INDEX IF NOT EXISTS "perms_package_best_permission_idx" ON "perms" ("package","best_permission");

-- 1 down
DROP TABLE IF EXISTS "packages";
DROP TABLE IF EXISTS "perms";

-- 2 up
CREATE TABLE IF NOT EXISTS "authors" (
  "cpanid" TEXT NOT NULL PRIMARY KEY,
  "fullname" TEXT NULL,
  "asciiname" TEXT NULL,
  "email" TEXT NULL,
  "homepage" TEXT NULL,
  "introduced" INTEGER NULL,
  "has_cpandir" INTEGER NULL
);

--2 down
DROP TABLE IF EXISTS "authors";

--3 up
CREATE TABLE "perms_new" (
  "package" TEXT NOT NULL,
  "userid" TEXT NOT NULL,
  "best_permission" TEXT NOT NULL CHECK ("best_permission" IN ('m','f','a','c')),
  PRIMARY KEY ("package","userid")
);
INSERT INTO "perms_new" SELECT * FROM "perms";
DROP TABLE "perms";
ALTER TABLE "perms_new" RENAME TO "perms";
CREATE INDEX IF NOT EXISTS "perms_userid_best_permission_idx" ON "perms" ("userid","best_permission");
CREATE INDEX IF NOT EXISTS "perms_package_best_permission_idx" ON "perms" ("package","best_permission");

--4 up
CREATE TABLE IF NOT EXISTS "refreshed" (
  "type" TEXT NOT NULL PRIMARY KEY,
  "last_updated" TEXT NOT NULL
);

--4 down
DROP TABLE IF EXISTS "refreshed";

--5 up
CREATE INDEX "packages_package_idx" ON "packages" ("package" COLLATE NOCASE);
DROP INDEX IF EXISTS "perms_userid_best_permission_idx";
DROP INDEX IF EXISTS "perms_package_best_permission_idx";
CREATE INDEX "perms_userid_best_permission_idx" ON "perms" ("userid" COLLATE NOCASE,"best_permission");
CREATE INDEX "perms_package_best_permission_idx" ON "perms" ("package" COLLATE NOCASE,"best_permission");
CREATE INDEX "authors_cpanid_idx" ON "authors" ("cpanid" COLLATE NOCASE);

--5 down
DROP INDEX IF EXISTS "packages_package_idx";
DROP INDEX IF EXISTS "authors_cpanid_idx";
