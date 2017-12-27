-- 1 up
CREATE TABLE IF NOT EXISTS "packages" (
  "package" CHARACTER VARYING NOT NULL PRIMARY KEY,
  "version" CHARACTER VARYING NULL,
  "path" CHARACTER VARYING NOT NULL
);
CREATE INDEX IF NOT EXISTS "packages_package_idx" ON "packages" (lower("package") text_pattern_ops);

CREATE TYPE "cpan_permission" AS ENUM ('m','f','a','c');
CREATE TABLE IF NOT EXISTS "perms" (
  "package" CHARACTER VARYING NOT NULL,
  "userid" CHARACTER VARYING NOT NULL,
  "best_permission" cpan_permission NOT NULL,
  PRIMARY KEY ("package","userid")
);
CREATE INDEX IF NOT EXISTS "perms_userid_best_permission_idx" ON "perms" (lower("userid") text_pattern_ops,"best_permission");
CREATE INDEX IF NOT EXISTS "perms_package_best_permission_idx" ON "perms" (lower("package") text_pattern_ops,"best_permission");

CREATE TABLE IF NOT EXISTS "authors" (
  "cpanid" CHARACTER VARYING NOT NULL PRIMARY KEY,
  "fullname" CHARACTER VARYING NULL,
  "asciiname" CHARACTER VARYING NULL,
  "email" CHARACTER VARYING NULL,
  "homepage" CHARACTER VARYING NULL,
  "introduced" BIGINT NULL,
  "has_cpandir" BOOLEAN NULL
);
CREATE INDEX IF NOT EXISTS "authors_cpanid_idx" ON "authors" (lower("cpanid") text_pattern_ops);

-- 1 down
DROP TABLE IF EXISTS "packages";
DROP TABLE IF EXISTS "perms";
DROP TABLE IF EXISTS "authors";
DROP TYPE IF EXISTS "cpan_permission";
