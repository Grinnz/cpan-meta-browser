package CPANMetaBrowser::Plugin::Backend::Pg;

# This software is Copyright (c) 2017 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Plugin';
use experimental 'signatures';
use Mojo::JSON qw(true false);
use Mojo::Pg;

sub register ($self, $app, $config) {
  my $pg_url = $ENV{CPAN_META_BROWSER_PG_URL} // $app->config->{pg_url} // die "'pg_url' config or 'CPAN_META_BROWSER_PG_URL' env required for pg backend\n";
  my $pg = Mojo::Pg->new($pg_url);
  my $migrations_path = $app->config->{migrations_path} // $app->home->child('cpan-meta-pg.sql');
  $pg->migrations->from_file($migrations_path)->migrate;
  
  $app->helper(pg => sub { $pg });
  
  $app->helper(get_packages => sub ($c, $module, $as_prefix) {
    my $details = [];
    my ($where, @params);
    if ($as_prefix) {
      $where = 'lower("p"."package") LIKE lower(?)';
      @params = (($module =~ s/([%_\\])/\\$1/gr) . '%');
    } else {
      $where = 'lower("p"."package") = lower(?)';
      @params = ($module);
    }
    my $query = 'SELECT "p"."package" AS "module", "p"."version", "p"."path",
      (SELECT "userid" FROM "perms" WHERE lower("package") = lower("p"."package") AND "best_permission"=? ORDER BY lower("userid") LIMIT 1) AS "owner"
      FROM "packages" AS "p" WHERE ' . $where . ' ORDER BY lower("p"."package")';
    $details = $c->pg->db->query($query, 'f', @params)->hashes;
    ($_->{uploader}) = $_->{path} =~ m{^[^/]+/[^/]+/([a-z]+)}i for @$details;
    return $details;
  });
  
  $app->helper(existing_packages => sub ($c, $db) {
    return $db->select('packages', ['package'])->arrays->map(sub { $_->[0] });
  });
  
  $app->helper(update_package => sub ($c, $db, $data) {
    my $current = $db->select('packages', '*', {package => $data->{package}})->hashes->first;
    return 1 if $c->_keys_equal($data, $current, [qw(version path)]);
    my $query = 'INSERT INTO "packages" ("package","version","path") VALUES (?,?,?)
      ON CONFLICT ("package") DO UPDATE SET "version" = EXCLUDED."version", "path" = EXCLUDED."path"';
    return $db->query($query, @$data{'package','version','path'});
  });
  
  $app->helper(delete_package => sub ($c, $db, $package) {
    return $db->delete('packages', {package => $package});
  });
  
  $app->helper(get_perms => sub ($c, $author, $module = '', $as_prefix = 0, $other_authors = 0) {
    return [] unless length $author or length $module;
    my $perms = [];
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
      if ($as_prefix) {
        push @where, 'lower("p"."package") LIKE lower(?)';
        push @params, ($module =~ s/([%_\\])/\\$1/gr) . '%';
      } else {
        push @where, 'lower("p"."package") = lower(?)';
        push @params, $module;
      }
    }
    my $where = join ' AND ', @where;
    my $query = 'SELECT "p"."package" AS "module", "p"."userid" AS "author", "p"."best_permission",
      (SELECT "userid" FROM "perms" WHERE lower("package") = lower("p"."package") AND "best_permission"=? ORDER BY lower("userid") LIMIT 1) AS "owner"
      FROM "perms" AS "p" WHERE ' . $where . ' ORDER BY lower("p"."package"), lower("p"."userid")';
    $perms = $c->pg->db->query($query, 'f', @params)->hashes;
    return $perms;
  });
  
  $app->helper(existing_perms => sub ($c, $db) {
    return $db->select('perms', ['userid','package'])->hashes;
  });
  
  $app->helper(update_perms => sub ($c, $db, $data) {
    my $current = $db->select('perms', '*', {package => $data->{package}, userid => $data->{userid}})->hashes->first;
    return 1 if $c->_keys_equal($data, $current, ['best_permission']);
    my $query = 'INSERT INTO "perms" ("package","userid","best_permission") VALUES (?,?,?)
      ON CONFLICT ("package","userid") DO UPDATE SET "best_permission" = EXCLUDED."best_permission"';
    return $db->query($query, @$data{'package','userid','best_permission'});
  });
  
  $app->helper(delete_perms => sub ($c, $db, $userid, $packages) {
    return $db->delete('perms', {userid => $userid, package => \['= ANY (?)', $packages]});
  });
  
  $app->helper(get_authors => sub ($c, $author, $as_prefix = 0) {
    my $details = [];
    my ($where, @params);
    if ($as_prefix) {
      $where = 'lower("cpanid") LIKE lower(?)';
      @params = (($author =~ s/([%_\\])/\\$1/gr) . '%');
    } else {
      $where = 'lower("cpanid") = lower(?)';
      @params = ($author);
    }
    my $query = 'SELECT "cpanid" AS "author", "fullname", "asciiname", "email", "homepage", "introduced", "has_cpandir"
      FROM "authors" WHERE ' . $where . ' ORDER BY lower("cpanid")';
    $details = $c->pg->db->query($query, @params)->hashes;
    $_->{has_cpandir} = $_->{has_cpandir} ? true : false for @$details;
    return $details;
  });
  
  $app->helper(existing_authors => sub ($c, $db) {
    return $db->select('authors', ['cpanid'])->arrays->map(sub { $_->[0] });
  });
  
  $app->helper(update_author => sub ($c, $db, $data) {
    my $current = $db->select('authors', '*', {cpanid => $data->{cpanid}})->hashes->first;
    return 1 if $c->_keys_equal($data, $current, [qw(fullname asciiname email homepage introduced has_cpandir)]);
    my $query = 'INSERT INTO "authors" ("cpanid","fullname","asciiname","email","homepage","introduced","has_cpandir") VALUES (?,?,?,?,?,?,?)
      ON CONFLICT ("cpanid") DO UPDATE SET "fullname" = EXCLUDED."fullname", "asciiname" = EXCLUDED."asciiname", "email" = EXCLUDED."email",
      "homepage" = EXCLUDED."homepage", "introduced" = EXCLUDED."introduced", "has_cpandir" = EXCLUDED."has_cpandir"';
    return $db->query($query, @$data{'cpanid','fullname','asciiname','email','homepage','introduced','has_cpandir'});
  });
  
  $app->helper(delete_author => sub ($c, $db, $cpanid) {
    return $db->delete('authors', {cpanid => $cpanid});
  });
  
  $app->helper(get_refreshed => sub ($c, $type) {
    my $query = 'SELECT extract(epoch from "last_updated") FROM "refreshed" WHERE "type" = ?';
    return +($c->pg->db->query($query, $type)->arrays->first // [])->[0];
  });
  
  $app->helper(update_refreshed => sub ($c, $db, $type, $time) {
    my $query = 'INSERT INTO "refreshed" ("type","last_updated") VALUES (?,to_timestamp(?))
      ON CONFLICT ("type") DO UPDATE SET "last_updated" = EXCLUDED."last_updated"';
    return $db->query($query, $type, $time);
  });
}

1;
