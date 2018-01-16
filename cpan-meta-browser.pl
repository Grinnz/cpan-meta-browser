#!/usr/bin/env perl

# This software is Copyright (c) 2017 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojolicious::Lite;
use experimental 'signatures';
use Mojo::JSON::MaybeXS;
use Mojo::JSON qw(true false);
use Mojo::URL;
use Mojo::Util 'trim';
use HTTP::Tiny;

use lib::relative 'lib';

plugin 'Config' => {file => 'cpan-meta-browser.conf', default => {}};

push @{app->commands->namespaces}, 'CPANMetaBrowser::Command';

my $httptiny;
helper 'httptiny' => sub { $httptiny //= HTTP::Tiny->new };

my $cache_dir = app->home->child('cache')->make_path;
helper 'cache_dir' => sub { $cache_dir };

my $backend = app->config->{backend} // 'sqlite';
if ($backend eq 'sqlite') {
  require Mojo::SQLite;
  my $sqlite_path = app->config->{sqlite_path} // app->home->child('cpan-meta.sqlite');
  my $sqlite = Mojo::SQLite->new->from_filename($sqlite_path);
  my $migrations_path = app->config->{migrations_path} // app->home->child('cpan-meta-sqlite.sql');
  $sqlite->migrations->from_file($migrations_path)->migrate;
  helper 'sqlite' => sub { $sqlite };
} elsif ($backend eq 'pg') {
  require Mojo::Pg;
  my $pg_url = app->config->{pg_url} // die "'pg_url' required for pg backend\n";
  my $pg = Mojo::Pg->new($pg_url);
  my $migrations_path = app->config->{migrations_path} // app->home->child('cpan-meta-pg.sql');
  $pg->migrations->from_file($migrations_path)->migrate;
  helper 'pg' => sub { $pg };
} elsif ($backend eq 'redis') {
  require Mojo::Redis2;
  my $redis_url = app->config->{redis_url};
  my $redis = Mojo::Redis2->new(defined $redis_url ? (url => $redis_url) : ());
  helper 'redis' => sub { $redis };
} else {
  die "Unknown backend '$backend' (should be 'sqlite' or 'pg')\n";
}
helper 'backend' => sub { $backend };

my $access_log = app->config->{access_log} // 'log/access.log';
my $old_level = app->log->level;
app->log->level('error'); # hack around AccessLog's dumb warning
plugin 'AccessLog' => {log => $access_log} if $access_log;
app->log->level($old_level);

get '/' => sub ($c) { $c->render('packages') } => 'index';
get '/packages';
get '/perms';
get '/module-perms' => sub ($c) { $c->redirect_to('perms') };
get '/author-perms' => sub ($c) { $c->redirect_to('perms') };
get '/authors';

get '/api/v1/packages/:module' => sub ($c) {
  my $module = trim($c->param('module') // '');
  my $as_prefix = $c->param('as_prefix');
  my $packages = $c->get_packages($module, $as_prefix);
  $c->render(json => $packages);
};

get '/api/v1/perms/by-module/:module' => sub ($c) {
  my $module = trim($c->param('module') // '');
  my $as_prefix = $c->param('as_prefix');
  my $perms = $c->get_perms('', $module, $as_prefix);
  $c->render(json => $perms);
};

get '/api/v1/perms/by-author/:author' => sub ($c) {
  my $author = trim($c->param('author') // '');
  my $perms = $c->get_perms($author);
  $c->render(json => $perms);
};

get '/api/v1/authors/:author' => sub ($c) {
  my $author = trim($c->param('author') // '');
  my $as_prefix = $c->param('as_prefix');
  my $authors = $c->get_authors($author, $as_prefix);
  $c->render(json => $authors);
};

get '/api/v2/packages/:module' => sub ($c) {
  my $module = trim($c->param('module') // '');
  my $as_prefix = $c->param('as_prefix');
  my $packages = $c->get_packages($module, $as_prefix);
  my $last_updated = $c->get_refreshed('packages');
  $c->render(json => {data => $packages, last_updated => $last_updated});
};

get '/api/v2/perms' => sub ($c) {
  my $author = trim($c->param('author') // '');
  my $module = trim($c->param('module') // '');
  my $as_prefix = $c->param('as_prefix');
  my $perms = $c->get_perms($author, $module, $as_prefix);
  my $last_updated = $c->get_refreshed('perms');
  $c->render(json => {data => $perms, last_updated => $last_updated});
};

get '/api/v2/authors/:author' => sub ($c) {
  my $author = trim($c->param('author') // '');
  my $as_prefix = $c->param('as_prefix');
  my $authors = $c->get_authors($author, $as_prefix);
  my $last_updated = $c->get_refreshed('authors');
  $c->render(json => {data => $authors, last_updated => $last_updated});
};

if ($backend eq 'sqlite') {
  helper get_packages => sub ($c, $module, $as_prefix) {
    my $details = [];
    my ($where, @params);
    if ($as_prefix) {
      $where = '"p"."package" LIKE ? ESCAPE ?';
      @params = (($module =~ s/[%_]/\\$1/gr) . '%', '\\');
    } else {
      $where = '"p"."package" COLLATE NOCASE = ?';
      @params = ($module);
    }
    my $query = 'SELECT "p"."package" AS "module", "p"."version", "p"."path",
      (SELECT "userid" FROM "perms" WHERE "package" = "p"."package" AND "best_permission"=? ORDER BY "userid" COLLATE NOCASE LIMIT 1) AS "owner"
      FROM "packages" AS "p" WHERE ' . $where . ' ORDER BY "p"."package" COLLATE NOCASE';
    $details = $c->sqlite->db->query($query, 'f', @params)->hashes;
    ($_->{uploader}) = $_->{path} =~ m{^[^/]+/[^/]+/([a-z]+)}i for @$details;
    return $details;
  };
  
  helper get_perms => sub ($c, $author, $module = '', $as_prefix = 0) {
    return [] unless length $author or length $module;
    my $perms = [];
    my (@where, @params);
    if (length $author) {
      push @where, '"p"."userid" COLLATE NOCASE = ?';
      push @params, $author;
    }
    if (length $module) {
      if ($as_prefix) {
        push @where, '"p"."package" LIKE ? ESCAPE ?';
        push @params, ($module =~ s/[%_]/\\$1/gr) . '%', '\\';
      } else {
        push @where, '"p"."package" COLLATE NOCASE = ?';
        push @params, $module;
      }
    }
    my $where = join ' AND ', @where;
    my $query = 'SELECT "p"."package" AS "module", "p"."userid" AS "author", "p"."best_permission",
      (SELECT "userid" FROM "perms" WHERE "package" = "p"."package" AND "best_permission"=? ORDER BY "userid" COLLATE NOCASE LIMIT 1) AS "owner"
      FROM "perms" AS "p" WHERE ' . $where . ' ORDER BY "p"."package" COLLATE NOCASE, "p"."userid" COLLATE NOCASE';
    $perms = $c->sqlite->db->query($query, 'f', @params)->hashes;
    return $perms;
  };
  
  helper get_authors => sub ($c, $author, $as_prefix = 0) {
    my $details = [];
    my ($where, @params);
    if ($as_prefix) {
      $where = '"cpanid" LIKE ? ESCAPE ?';
      @params = (($author =~ s/[%_]/\\$1/gr) . '%', '\\');
    } else {
      $where = '"cpanid" COLLATE NOCASE = ?';
      @params = ($author);
    }
    my $query = 'SELECT "cpanid" AS "author", "fullname", "asciiname", "email", "homepage", "introduced", "has_cpandir"
      FROM "authors" WHERE ' . $where . ' ORDER BY "cpanid" COLLATE NOCASE';
    $details = $c->sqlite->db->query($query, @params)->hashes;
    $_->{has_cpandir} = $_->{has_cpandir} ? true : false for @$details;
    return $details;
  };
  
  helper get_refreshed => sub ($c, $type) {
    my $query = q{SELECT strftime('%s',"last_updated") FROM "refreshed" WHERE "type" = ?};
    return +($c->sqlite->db->query($query, $type)->arrays->first // [])->[0];
  };
} elsif ($backend eq 'pg') {
  helper get_packages => sub ($c, $module, $as_prefix) {
    my $details = [];
    my ($where, @params);
    if ($as_prefix) {
      $where = 'lower("p"."package") LIKE lower(?)';
      @params = (($module =~ s/[%_]/\\$1/gr) . '%');
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
  };
  
  helper get_perms => sub ($c, $author, $module = '', $as_prefix = 0) {
    return [] unless length $author or length $module;
    my $perms = [];
    my (@where, @params);
    if (length $author) {
      push @where, 'lower("p"."userid") = lower(?)';
      push @params, $author;
    }
    if (length $module) {
      if ($as_prefix) {
        push @where, 'lower("p"."package") LIKE lower(?)';
        push @params, ($module =~ s/[%_]/\\$1/gr) . '%';
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
  };
  
  helper get_authors => sub ($c, $author, $as_prefix = 0) {
    my $details = [];
    my ($where, @params);
    if ($as_prefix) {
      $where = 'lower("cpanid") LIKE lower(?)';
      @params = (($author =~ s/[%_]/\\$1/gr) . '%');
    } else {
      $where = 'lower("cpanid") = lower(?)';
      @params = ($author);
    }
    my $query = 'SELECT "cpanid" AS "author", "fullname", "asciiname", "email", "homepage", "introduced", "has_cpandir"
      FROM "authors" WHERE ' . $where . ' ORDER BY lower("cpanid")';
    $details = $c->pg->db->query($query, @params)->hashes;
    $_->{has_cpandir} = $_->{has_cpandir} ? true : false for @$details;
    return $details;
  };
  
  helper get_refreshed => sub ($c, $type) {
    my $query = 'SELECT extract(epoch from "last_updated") FROM "refreshed" WHERE "type" = ?';
    return +($c->pg->db->query($query, $type)->arrays->first // [])->[0];
  };
} elsif ($backend eq 'redis') {
  helper get_packages => sub ($c, $module, $as_prefix) {
    my $details = [];
    my $redis = $c->redis;
    my $packages_lc;
    my $start = lc $module;
    if ($as_prefix) {
      my $end = $start =~ s/(.)\z/chr(ord($1)+1)/er;
      $packages_lc = $redis->zrangebylex('cpanmeta.packages_sorted', "[$start", "($end");
    } else {
      $packages_lc = $redis->zrangebylex('cpanmeta.packages_sorted', "[$start", "[$start");
    }
    foreach my $package_lc (@$packages_lc) {
      my $package = $redis->hget('cpanmeta.packages_lc', $package_lc) // next;
      my %package_details = @{$redis->hgetall("cpanmeta.package.$package")};
      my $owner = $redis->hget('cpanmeta.package_owners', $package);
      push @$details, {
        module => $package_details{package},
        version => $package_details{version},
        path => $package_details{path},
        owner => $owner,
      };
    }
    ($_->{uploader}) = $_->{path} =~ m{^[^/]+/[^/]+/([a-z]+)}i for @$details;
    return $details;
  };
  
  helper get_perms => sub ($c, $author, $module = '', $as_prefix = 0) {
    return [] unless length $author or length $module;
    my $perms = [];
    my $redis = $c->redis;
    my @userid_packages;
    if (length $author) {
      my $start = lc $author;
      my ($userid_lc) = @{$redis->zrangebylex('cpanmeta.perms_userids_sorted', "[$start", "[$start")};
      if (defined $userid_lc) {
        my $userid = $redis->hget('cpanmeta.perms_userids_lc', $userid_lc);
        if (defined $userid) {
          my @range = ('-', '+');
          if (length $module) {
            my $start = lc $module;
            if ($as_prefix) {
              my $end = $start =~ s/(.)\z/chr(ord($1)+1)/er;
              @range = ("[$start", "($end");
            } else {
              @range = ("[$start", "[$start");
            }
          }
          my $packages_lc = $redis->zrangebylex("cpanmeta.perms_packages_for_userid.$userid", @range);
          foreach my $package_lc (@$packages_lc) {
            my $package = $redis->hget('cpanmeta.perms_packages_lc', $package_lc) // next;
            my $owner = $redis->hget('cpanmeta.package_owners', $package);
            push @userid_packages, [$userid, $package, $owner];
          }
        }
      }
    } else {
      my $packages_lc;
      my $start = lc $module;
      if ($as_prefix) {
        my $end = $start =~ s/(.)\z/chr(ord($1)+1)/er;
        $packages_lc = $redis->zrangebylex('cpanmeta.perms_packages_sorted', "[$start", "($end");
      } else {
        $packages_lc = $redis->zrangebylex('cpanmeta.perms_packages_sorted', "[$start", "[$start");
      }
      foreach my $package_lc (@$packages_lc) {
        my $package = $redis->hget('cpanmeta.perms_packages_lc', $package_lc) // next;
        my $owner = $redis->hget('cpanmeta.package_owners', $package);
        my $userids_lc = $redis->zrangebylex("cpanmeta.perms_userids_for_package.$package", '-', '+');
        foreach my $userid_lc (@$userids_lc) {
          my $userid = $redis->hget('cpanmeta.perms_userids_lc', $userid_lc) // next;
          push @userid_packages, [$userid, $package, $owner];
        }
      }
    }
    foreach my $userid_package (@userid_packages) {
      my ($userid, $package, $owner) = @$userid_package;
      my %perms_details = @{$redis->hgetall("cpanmeta.perms.$userid/$package")};
      push @$perms, {
        author => $perms_details{userid},
        module => $perms_details{package},
        best_permission => $perms_details{best_permission},
        owner => $owner,
      };
    }
    return $perms;
  };
  
  helper get_authors => sub ($c, $author, $as_prefix = 0) {
    my $details = [];
    my $redis = $c->redis;
    my $cpanids_lc;
    my $start = lc $author;
    if ($as_prefix) {
      my $end = $start =~ s/(.)\z/chr(ord($1)+1)/er;
      $cpanids_lc = $redis->zrangebylex('cpanmeta.cpanids_sorted', "[$start", "($end");
    } else {
      $cpanids_lc = $redis->zrangebylex('cpanmeta.cpanids_sorted', "[$start", "[$start");
    }
    foreach my $cpanid_lc (@$cpanids_lc) {
      my $cpanid = $redis->hget('cpanmeta.cpanids_lc', $cpanid_lc) // next;
      my %author = @{$redis->hgetall("cpanmeta.author.$cpanid")};
      push @$details, {
        author => $author{cpanid},
        fullname => $author{fullname},
        asciiname => $author{asciiname},
        email => $author{email},
        homepage => $author{homepage},
        introduced => $author{introduced},
        has_cpandir => $author{has_cpandir},
      };
    }
    $_->{has_cpandir} = $_->{has_cpandir} ? true : false for @$details;
    return $details;
  };
  
  helper get_refreshed => sub ($c, $type) {
    return $c->redis->hget('cpanmeta.refreshed', $type);
  };
}

app->start;

