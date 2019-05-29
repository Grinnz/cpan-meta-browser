package CPANMetaBrowser::Plugin::Backend::Pg;

# This software is Copyright (c) 2017 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use Mojo::JSON qw(true false);
use Mojo::Pg 4.08;

sub register ($self, $app, $config) {
  {
    my $pg_url = $ENV{CPAN_META_BROWSER_PG_URL} // $app->config->{pg_url} // die "'pg_url' config or 'CPAN_META_BROWSER_PG_URL' env required for pg backend\n";
    my $pg = Mojo::Pg->new($pg_url);
    $pg->migrations->from_data->migrate;
    
    $app->helper(pg => sub { $pg });
  }
  
  $app->helper(get_packages => sub ($c, $module, $as_prefix = 0, $as_infix = 0) {
    return [] unless length $module;
    my ($where, @params);
    if (ref $module eq 'ARRAY') {
      $where = 'lower("p"."package") = ANY(?)';
      @params = [map { lc } @$module];
    } elsif ($as_infix) {
      $where = 'lower("p"."package") LIKE lower(?)';
      @params = ('%' . $c->_sql_pattern_escape($module) . '%');
    } elsif ($as_prefix) {
      $where = 'lower("p"."package") LIKE lower(?)';
      @params = ($c->_sql_pattern_escape($module) . '%');
    } else {
      $where = 'lower("p"."package") = lower(?)';
      @params = ($module);
    }
    my $query = 'SELECT "p"."package" AS "module", "p"."version", "p"."path",
      (SELECT "userid" FROM "perms" WHERE lower("package") = lower("p"."package") AND "best_permission"=? ORDER BY lower("userid") LIMIT 1) AS "owner"
      FROM "packages" AS "p" WHERE ' . $where . ' ORDER BY lower("p"."package")';
    my $details = $c->pg->db->query($query, 'f', @params)->hashes;
    ($_->{uploader}) = $_->{path} =~ m{^[^/]+/[^/]+/([a-z]+)}i for @$details;
    return $details;
  });
  
  $app->helper(existing_packages => sub ($c, $db) {
    return $db->select('packages', ['package'])->arrays->map(sub { $_->[0] });
  });
  
  $app->helper(update_package => sub ($c, $db, $data) {
    my $current = $db->select('packages', ['*'], {package => $data->{package}})->hashes->first;
    return 1 if $c->_keys_equal($data, $current, [qw(version path)]);
    return $db->insert('packages', {%$data{qw(package version path)}},
      {on_conflict => ['package', {map {($_ => \qq{EXCLUDED."$_"})} qw(version path)}]});
  });
  
  $app->helper(delete_package => sub ($c, $db, $package) {
    return $db->delete('packages', {package => $package});
  });
  
  $app->helper(get_perms => sub ($c, $author, $module = '', $as_prefix = 0, $as_infix = 0, $other_authors = 0) {
    return [] unless length $author or length $module;
    my (@where, @params);
    if (length $author) {
      if ($other_authors) {
        push @where, '"p"."package" IN (SELECT "package" FROM "perms" WHERE lower("userid") = lower(?))';
        push @params, $author;
      } else {
        push @where, 'lower("p"."userid") = lower(?)';
        push @params, $author;
      }
    }
    if (length $module) {
      if ($as_infix) {
        push @where, 'lower("p"."package") LIKE lower(?)';
        push @params, '%' . $c->_sql_pattern_escape($module) . '%';
      } elsif ($as_prefix) {
        push @where, 'lower("p"."package") LIKE lower(?)';
        push @params, $c->_sql_pattern_escape($module) . '%';
      } else {
        push @where, 'lower("p"."package") = lower(?)';
        push @params, $module;
      }
    }
    my $where = join ' AND ', @where;
    my $query = 'SELECT "p"."package" AS "module", "p"."userid" AS "author", "p"."best_permission",
      (SELECT "userid" FROM "perms" WHERE lower("package") = lower("p"."package") AND "best_permission"=? ORDER BY lower("userid") LIMIT 1) AS "owner"
      FROM "perms" AS "p" WHERE ' . $where . ' ORDER BY lower("p"."package"), lower("p"."userid")';
    my $perms = $c->pg->db->query($query, 'f', @params)->hashes;
    return $perms;
  });
  
  $app->helper(existing_perms => sub ($c, $db) {
    return $db->select('perms', ['userid','package'])->hashes;
  });
  
  $app->helper(update_perms => sub ($c, $db, $data) {
    my $current = $db->select('perms', ['*'], {%$data{qw(package userid)}})->hashes->first;
    return 1 if $c->_keys_equal($data, $current, ['best_permission']);
    return $db->insert('perms', {%$data{qw(package userid best_permission)}},
      {on_conflict => \'("package","userid") DO UPDATE SET "best_permission"=EXCLUDED."best_permission"'});
  });
  
  $app->helper(delete_perms => sub ($c, $db, $userid, $packages) {
    return $db->delete('perms', {userid => $userid, package => \['= ANY (?)', $packages]});
  });
  
  $app->helper(get_authors => sub ($c, $author, $as_prefix = 0, $as_infix = 0) {
    return [] unless length $author;
    my ($where, @params);
    if ($as_infix) {
      $where = 'lower("cpanid") LIKE lower(?)';
      @params = ('%' . $c->_sql_pattern_escape($author) . '%');
    } elsif ($as_prefix) {
      $where = 'lower("cpanid") LIKE lower(?)';
      @params = ($c->_sql_pattern_escape($author) . '%');
    } else {
      $where = 'lower("cpanid") = lower(?)';
      @params = ($author);
    }
    my $query = 'SELECT "cpanid" AS "author", "fullname", "asciiname", "email", "homepage", "introduced", "has_cpandir"
      FROM "authors" WHERE ' . $where . ' ORDER BY lower("cpanid")';
    my $details = $c->pg->db->query($query, @params)->hashes;
    $_->{has_cpandir} = $_->{has_cpandir} ? true : false for @$details;
    return $details;
  });
  
  $app->helper(existing_authors => sub ($c, $db) {
    return $db->select('authors', ['cpanid'])->arrays->map(sub { $_->[0] });
  });
  
  $app->helper(update_author => sub ($c, $db, $data) {
    my $current = $db->select('authors', ['*'], {cpanid => $data->{cpanid}})->hashes->first;
    return 1 if $c->_keys_equal($data, $current, [qw(fullname asciiname email homepage introduced has_cpandir)]);
    return $db->insert('authors', {%$data{qw(cpanid fullname asciiname email homepage introduced has_cpandir)}},
      {on_conflict => ['cpanid', {map {($_ => \qq{EXCLUDED."$_"})} qw(fullname asciiname email homepage introduced has_cpandir)}]});
  });
  
  $app->helper(delete_author => sub ($c, $db, $cpanid) {
    return $db->delete('authors', {cpanid => $cpanid});
  });
  
  $app->helper(get_refreshed => sub ($c, $type) {
    my $refreshed = $c->pg->db->select('refreshed', [\'extract(epoch from "last_updated")'], {type => $type});
    return +($refreshed->arrays->first // [])->[0];
  });
  
  $app->helper(update_refreshed => sub ($c, $db, $type, $time) {
    return $db->insert('refreshed', {type => $type, last_updated => \['to_timestamp(?)', $time]},
      {on_conflict => ['type', {last_updated => \'EXCLUDED."last_updated"'}]});
  });
}

1;

__DATA__
@@ migrations
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

--2 up
CREATE TABLE IF NOT EXISTS "refreshed" (
  "type" CHARACTER VARYING NOT NULL PRIMARY KEY,
  "last_updated" TIMESTAMP WITH TIME ZONE NOT NULL
);

--2 down
DROP TABLE IF EXISTS "refreshed";

--3 up
CREATE INDEX IF NOT EXISTS "packages_package_trgm_idx" ON "packages" USING GIN (lower("package") gin_trgm_ops);
CREATE INDEX IF NOT EXISTS "perms_userid_trgm_idx" ON "perms" USING GIN (lower("userid") gin_trgm_ops);
CREATE INDEX IF NOT EXISTS "perms_package_trgm_idx" ON "perms" USING GIN (lower("package") gin_trgm_ops);
CREATE INDEX IF NOT EXISTS "authors_cpanid_trgm_idx" ON "authors" USING GIN (lower("cpanid") gin_trgm_ops);
