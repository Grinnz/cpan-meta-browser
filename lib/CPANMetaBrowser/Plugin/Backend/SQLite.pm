package CPANMetaBrowser::Plugin::Backend::SQLite;

# This software is Copyright (c) 2017 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use Mojo::JSON qw(true false);
use Mojo::SQLite 2.001;

sub register ($self, $app, $config) {
  {
    my $sqlite_path = $ENV{CPAN_META_BROWSER_SQLITE_PATH} // $app->config->{sqlite_path} // $app->home->child('cpan-meta.sqlite');
    my $sqlite = Mojo::SQLite->new->from_filename($sqlite_path);
    $sqlite->migrations->from_data->migrate;
    
    $app->helper(sqlite => sub { $sqlite });
  }
  
  $app->helper(get_packages => sub ($c, $module, $as_prefix = 0, $as_infix = 0) {
    return [] unless length $module;
    my ($where, @params);
    if (ref $module eq 'ARRAY') {
      my $in = join ',', ('?')x@$module;
      $where = '"p"."package" COLLATE NOCASE IN (' . $in . ')';
      @params = @$module;
    } elsif ($as_infix) {
      $where = '"p"."package" LIKE ? ESCAPE ?';
      @params = ('%' . $c->_sql_pattern_escape($module) . '%', '\\');
    } elsif ($as_prefix) {
      $where = '"p"."package" LIKE ? ESCAPE ?';
      @params = ($c->_sql_pattern_escape($module) . '%', '\\');
    } else {
      $where = '"p"."package" COLLATE NOCASE = ?';
      @params = ($module);
    }
    my $query = 'SELECT "p"."package" AS "module", "p"."version", "p"."path",
      (SELECT "userid" FROM "perms" WHERE "package" = "p"."package" AND "best_permission"=? ORDER BY "userid" COLLATE NOCASE LIMIT 1) AS "owner"
      FROM "packages" AS "p" WHERE ' . $where . ' ORDER BY "p"."package" COLLATE NOCASE';
    my $details = $c->sqlite->db->query($query, 'f', @params)->hashes;
    ($_->{uploader}) = $_->{path} =~ m{^[^/]+/[^/]+/([a-z]+)}i for @$details;
    return $details;
  });
  
  $app->helper(existing_packages => sub ($c, $db) {
    return $db->select('packages', ['package'])->arrays->map(sub { $_->[0] });
  });
  
  $app->helper(update_package => sub ($c, $db, $data) {
    my $current = $db->select('packages', ['*'], {package => $data->{package}})->hashes->first;
    return 1 if $c->_keys_equal($data, $current, [qw(version path)]);
    my $query = 'INSERT OR REPLACE INTO "packages" ("package","version","path") VALUES (?,?,?)';
    return $db->query($query, @$data{'package','version','path'});
  });
  
  $app->helper(delete_package => sub ($c, $db, $package) {
    return $db->delete('packages', {package => $package});
  });
  
  $app->helper(get_perms => sub ($c, $author, $module = '', $as_prefix = 0, $as_infix = 0, $other_authors = 0) {
    return [] unless length $author or length $module;
    my (@where, @params);
    if (length $author) {
      if ($other_authors) {
        push @where, '"p"."package" IN (SELECT "package" FROM "perms" WHERE "userid" COLLATE NOCASE = ?)';
        push @params, $author;
      } else {
        push @where, '"p"."userid" COLLATE NOCASE = ?';
        push @params, $author;
      }
    }
    if (length $module) {
      if ($as_infix) {
        push @where, '"p"."package" LIKE ? ESCAPE ?';
        push @params, '%' . $c->_sql_pattern_escape($module) . '%', '\\';
      } elsif ($as_prefix) {
        push @where, '"p"."package" LIKE ? ESCAPE ?';
        push @params, $c->_sql_pattern_escape($module) . '%', '\\';
      } else {
        push @where, '"p"."package" COLLATE NOCASE = ?';
        push @params, $module;
      }
    }
    my $where = join ' AND ', @where;
    my $query = 'SELECT "p"."package" AS "module", "p"."userid" AS "author", "p"."best_permission",
      (SELECT "userid" FROM "perms" WHERE "package" = "p"."package" AND "best_permission"=? ORDER BY "userid" COLLATE NOCASE LIMIT 1) AS "owner"
      FROM "perms" AS "p" WHERE ' . $where . ' ORDER BY "p"."package" COLLATE NOCASE, "p"."userid" COLLATE NOCASE';
    my $perms = $c->sqlite->db->query($query, 'f', @params)->hashes;
    return $perms;
  });
  
  $app->helper(existing_perms => sub ($c, $db) {
    return $db->select('perms', ['userid','package'])->hashes;
  });
  
  $app->helper(update_perms => sub ($c, $db, $data) {
    my $current = $db->select('perms', ['*'], {%$data{qw(package userid)}})->hashes->first;
    return 1 if $c->_keys_equal($data, $current, ['best_permission']);
    my $query = 'INSERT OR REPLACE INTO "perms" ("package","userid","best_permission") VALUES (?,?,?)';
    return $db->query($query, @$data{'package','userid','best_permission'});
  });
  
  $app->helper(delete_perms => sub ($c, $db, $userid, $packages) {
    return $db->delete('perms', {userid => $userid, package => {-in => $packages}});
  });
  
  $app->helper(get_authors => sub ($c, $author, $as_prefix = 0, $as_infix = 0) {
    return [] unless length $author;
    my ($where, @params);
    if ($as_infix) {
      $where = '"cpanid" LIKE ? ESCAPE ?';
      @params = ('%' . $c->_sql_pattern_escape($author) . '%', '\\');
    } elsif ($as_prefix) {
      $where = '"cpanid" LIKE ? ESCAPE ?';
      @params = ($c->_sql_pattern_escape($author) . '%', '\\');
    } else {
      $where = '"cpanid" COLLATE NOCASE = ?';
      @params = ($author);
    }
    my $query = 'SELECT "cpanid" AS "author", "type", "fullname", "asciiname", "email", "homepage", "info", "introduced", "has_cpandir"
      FROM "authors" WHERE ' . $where . ' ORDER BY "cpanid" COLLATE NOCASE';
    my $details = $c->sqlite->db->query($query, @params)->hashes;
    $_->{has_cpandir} = $_->{has_cpandir} ? true : false for @$details;
    return $details;
  });
  
  $app->helper(existing_authors => sub ($c, $db) {
    return $db->select('authors', ['cpanid'])->arrays->map(sub { $_->[0] });
  });
  
  $app->helper(update_author => sub ($c, $db, $data) {
    my $current = $db->select('authors', ['*'], {cpanid => $data->{cpanid}})->hashes->first;
    return 1 if $c->_keys_equal($data, $current, [qw(type fullname asciiname email homepage info introduced has_cpandir)]);
    my $query = 'INSERT OR REPLACE INTO "authors" ("cpanid","type","fullname","asciiname","email","homepage","info","introduced","has_cpandir") VALUES (?,?,?,?,?,?,?,?,?)';
    return $db->query($query, @$data{'cpanid','type','fullname','asciiname','email','homepage','info','introduced','has_cpandir'});
  });
  
  $app->helper(delete_author => sub ($c, $db, $cpanid) {
    return $db->delete('authors', {cpanid => $cpanid});
  });
  
  $app->helper(get_refreshed => sub ($c, $type) {
    my $refreshed = $c->sqlite->db->select('refreshed', [\q{strftime('%s',"last_updated")}], {type => $type});
    return +($refreshed->arrays->first // [])->[0];
  });
  
  $app->helper(update_refreshed => sub ($c, $db, $type, $time) {
    my $query = q{INSERT OR REPLACE INTO "refreshed" ("type","last_updated") VALUES (?,datetime(?, 'unixepoch'))};
    return $db->query($query, $type, $time);
  });
}

1;

__DATA__
@@ migrations
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

--6 up
CREATE TABLE "perms_new" (
  "package" TEXT NOT NULL,
  "userid" TEXT NOT NULL,
  "best_permission" TEXT NOT NULL CHECK ("best_permission" IN ('m','f','p','c')),
  PRIMARY KEY ("package","userid")
);
INSERT INTO "perms_new" SELECT * FROM "perms";
DROP TABLE "perms";
ALTER TABLE "perms_new" RENAME TO "perms";
CREATE INDEX "perms_userid_best_permission_idx" ON "perms" ("userid" COLLATE NOCASE,"best_permission");
CREATE INDEX "perms_package_best_permission_idx" ON "perms" ("package" COLLATE NOCASE,"best_permission");

CREATE TABLE "authors_new" (
  "cpanid" TEXT NOT NULL PRIMARY KEY,
  "type" TEXT NOT NULL DEFAULT 'author' CHECK ("type" IN ('author','list')),
  "fullname" TEXT NULL,
  "asciiname" TEXT NULL,
  "email" TEXT NULL,
  "homepage" TEXT NULL,
  "info" TEXT NULL,
  "introduced" INTEGER NULL,
  "has_cpandir" INTEGER NULL
);
INSERT INTO "authors_new" ("cpanid","fullname","asciiname","email","homepage","introduced","has_cpandir")
  SELECT "cpanid","fullname","asciiname","email","homepage","introduced","has_cpandir" FROM "authors";
DROP TABLE "authors";
ALTER TABLE "authors_new" RENAME TO "authors";
CREATE INDEX "authors_cpanid_idx" ON "authors" ("cpanid" COLLATE NOCASE);
