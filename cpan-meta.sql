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
