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
get '/module-perms' => 'module-perms';
get '/author-perms' => 'author-perms';
get '/authors';

get '/api/v1/packages/:module' => sub ($c) {
  my $module = trim($c->param('module') // '');
  my $as_prefix = $c->param('as_prefix');
  my ($where, @params);
  if ($as_prefix) {
    $where = '"p"."package" LIKE ? ESCAPE ?';
    @params = (($module =~ s/[%_]/\\$1/gr) . '%', '\\');
  } else {
    $where = '"p"."package" COLLATE NOCASE = ?';
    @params = ($module);
  }
  my $details = $c->sqlite->db->query('SELECT "p"."package" AS "module", "p"."version", "p"."path",
    (SELECT "userid" FROM "perms" WHERE "package"="p"."package" AND "best_permission"=? ORDER BY "userid" COLLATE NOCASE LIMIT 1) AS "owner"
    FROM "packages" AS "p" WHERE ' . $where . ' ORDER BY "p"."package" COLLATE NOCASE', 'f', @params)->hashes;
  ($_->{uploader}) = $_->{path} =~ m{^[^/]+/[^/]+/([a-z]+)}i for @$details;
  $c->render(json => $details);
};

get '/api/v1/perms/by-module/:module' => sub ($c) {
  my $module = trim($c->param('module') // '');
  my $as_prefix = $c->param('as_prefix');
  my ($where, @params);
  if ($as_prefix) {
    $where = '"p"."package" LIKE ? ESCAPE ?';
    @params = (($module =~ s/[%_]/\\$1/gr) . '%', '\\');
  } else {
    $where = '"p"."package" COLLATE NOCASE = ?';
    @params = ($module);
  }
  my $perms = $c->sqlite->db->query('SELECT "p"."package" AS "module", "p"."userid" AS "author", "p"."best_permission",
    (SELECT "userid" FROM "perms" WHERE "package"="p"."package" AND "best_permission"=? ORDER BY "userid" COLLATE NOCASE LIMIT 1) AS "owner"
    FROM "perms" AS "p" WHERE ' . $where . ' ORDER BY "p"."package" COLLATE NOCASE, "p"."userid" COLLATE NOCASE', 'f', @params)->hashes;
  $c->render(json => $perms);
};

get '/api/v1/perms/by-author/:author' => sub ($c) {
  my $author = trim($c->param('author') // '');
  my $perms = $c->sqlite->db->query('SELECT "p"."userid" AS "author", "p"."package" AS "module", "p"."best_permission",
    (SELECT "userid" FROM "perms" WHERE "package"="p"."package" AND "best_permission"=? ORDER BY "userid" COLLATE NOCASE LIMIT 1) AS "owner"
    FROM "perms" AS "p" WHERE "p"."userid" COLLATE NOCASE = ? ORDER BY "p"."package" COLLATE NOCASE', 'f', $author)->hashes;
  $c->render(json => $perms);
};

get '/api/v1/authors/:author' => sub ($c) {
  my $author = trim($c->param('author') // '');
  my $as_prefix = $c->param('as_prefix');
  my ($where, @params);
  if ($as_prefix) {
    $where = '"cpanid" LIKE ? ESCAPE ?';
    @params = (($author =~ s/[%_]/\\$1/gr) . '%', '\\');
  } else {
    $where = '"cpanid" COLLATE NOCASE = ?';
    @params = ($author);
  }
  my $details = $c->sqlite->db->query('SELECT "cpanid" AS "author", "fullname", "asciiname", "email", "homepage", "introduced", "has_cpandir"
    FROM "authors" WHERE ' . $where . ' ORDER BY "cpanid" COLLATE NOCASE', @params)->hashes;
  $_->{has_cpandir} = $_->{has_cpandir} ? true : false for @$details;
  $c->render(json => $details);
};

app->start;

