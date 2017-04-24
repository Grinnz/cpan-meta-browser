#!/usr/bin/env perl

# This software is Copyright (c) 2017 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

package CPANMetaBrowser::Command::refresh {
use Mojo::Base 'Mojolicious::Command';
use experimental 'signatures';
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use Mojo::DOM;
use Mojo::File 'path';
use Mojo::URL;
use Mojo::Util 'decode';
use Syntax::Keyword::Try;
use Text::CSV_XS;

use constant CPAN_MIRROR_METACPAN => 'https://cpan.metacpan.org/';

sub run ($self) {
  try {
    prepare_02packages($self->app);
    prepare_06perms($self->app);
    prepare_00whois($self->app);
    $self->app->log->debug('Refreshed cpan-meta database');
    print "Refreshed cpan-meta database\n";
  } catch {
    $self->app->log->error("Failed to refresh cpan-meta database: $@");
    die "Failed to refresh cpan-meta database: $@";
  }
}

sub cache_file ($app, $filename, $inflate = 0) {
  my $url = Mojo::URL->new(CPAN_MIRROR_METACPAN)->path($filename);
  my $local_path = $app->cache_dir->child($filename);
  $local_path->dirname->make_path;
  my $res = $app->httptiny->mirror($url, $local_path);
  die "Failed to cache file from $url to $local_path: $res->{content}\n" if $res->{status} == 599;
  die "Failed to cache file from $url to $local_path: $res->{status} $res->{reason}\n" unless $res->{success};
  $app->log->debug("Cached file from $url to $local_path: $res->{status} $res->{reason}");
  if ($inflate) {
    my $unzipped_path = $local_path =~ s/\.gz\z//r;
    return $local_path if $local_path eq $unzipped_path;
    my $rc = gunzip("$local_path" => "$unzipped_path") or die "Failed to gunzip $local_path: $GunzipError\n";
    $app->log->debug("Inflated $local_path to $unzipped_path");
    return $unzipped_path;
  } else {
    return $local_path;
  }
}

sub prepare_02packages ($app) {
  my $packages_path = cache_file($app, 'modules/02packages.details.txt.gz', 1);
  
  my $fh = path($packages_path)->open('r');
  while (defined(my $line = readline $fh)) {
    last if $line =~ m/^\s*$/;
  }
  
  my $db = $app->sqlite->db;
  my $tx = $db->begin;
  $db->delete('packages');
  
  while (defined(my $line = readline $fh)) {
    chomp $line;
    my ($package, $version, $path) = split /\s+/, $line, 3;
    next unless length $version;
    $version = undef if $version eq 'undef';
    $db->insert('packages', {package => $package, version => $version, path => ($path // '')});
  }
  $tx->commit;
}

my %valid_permission = (m => 1, f => 1, c => 1);
sub prepare_06perms ($app) {
  my $perms_path = cache_file($app, 'modules/06perms.txt.gz', 1);
  
  my $fh = path($perms_path)->open('r');
  while (defined(my $line = readline $fh)) {
    last if $line =~ m/^\s*$/;
  }
  
  my $db = $app->sqlite->db;
  my $tx = $db->begin;
  $db->delete('perms');
  
  my $csv = Text::CSV_XS->new({binary => 1});
  $csv->bind_columns(\my $package, \my $userid, \my $best_permission);
  while ($csv->getline($fh)) {
    next unless length $package and length $userid and length $best_permission;
    unless (exists $valid_permission{$best_permission}) {
      $app->log->warn("06perms.txt: Found invalid permission type $best_permission for $userid on module $package");
      next;
    }
    $db->insert('perms', {package => $package, userid => $userid, best_permission => $best_permission});
  }
  $tx->commit;
}

sub prepare_00whois ($app) {
  my $whois_path = cache_file($app, 'authors/00whois.xml');
  
  my $contents = decode 'UTF-8', path($whois_path)->slurp;
  
  my $dom = Mojo::DOM->new->xml(1)->parse($contents);
  
  my $db = $app->sqlite->db;
  my $tx = $db->begin;
  $db->delete('authors');
  
  foreach my $author (@{$dom->find('cpanid')}) {
    next unless $author->at('type')->text eq 'author';
    my %details;
    foreach my $detail (qw(id fullname asciiname email homepage introduced has_cpandir)) {
      my $elem = $author->at($detail) // next;
      $details{$detail} = $elem->text;
    }
    next unless defined $details{id};
    $db->insert('authors', {cpanid => $details{id}, fullname => $details{fullname}, asciiname => $details{asciiname}, email => $details{email},
      homepage => $details{homepage}, introduced => $details{introduced}, has_cpandir => $details{has_cpandir}});
  }
  $tx->commit;
}

} # end CPANMetaBrowser::Command::refresh

use Mojolicious::Lite;
use experimental 'signatures';
use Mojo::JSON::MaybeXS;
use Mojo::JSON qw(true false);
use Mojo::SQLite;
use Mojo::URL;
use Mojo::Util 'trim';
use HTTP::Tiny;

my $cache_dir = app->home->child('cache')->make_path;

my $sqlite_path = app->home->child('cpan-meta.sqlite');
my $sqlite = Mojo::SQLite->new->from_filename($sqlite_path);
$sqlite->migrations->from_data(__PACKAGE__, 'cpan-meta.sql')->migrate;

push @{app->commands->namespaces}, 'CPANMetaBrowser::Command';

my $httptiny;
helper 'httptiny' => sub { $httptiny //= HTTP::Tiny->new };
helper 'cache_dir' => sub { $cache_dir };
helper 'sqlite' => sub { $sqlite };

plugin 'Config' => {file => 'cpan-meta-browser.conf', default => {}};
my $access_log = app->config->{access_log} // 'log/access.log';

my $old_level = app->log->level;
app->log->level('error'); # hack around AccessLog's dumb warning
plugin 'AccessLog' => {log => $access_log} if $access_log;
app->log->level($old_level);

get '/' => 'index';

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

__DATA__
@@ cpan-meta.sql

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
