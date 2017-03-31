#!/usr/bin/env perl

# This software is Copyright (c) 2017 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use Mojolicious::Lite;
use experimental 'signatures';
use Mojo::IOLoop;
use Mojo::SQLite;
use Mojo::URL;
use File::Open 'fopen';
use HTTP::Tiny;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use Text::CSV_XS;
use Time::Seconds;

use constant CPAN_MIRROR_METACPAN => 'https://cpan.metacpan.org/';

my $cache_dir = app->home->child('cache')->make_path;
my $ua = HTTP::Tiny->new;

my $sqlite_path = app->home->child('cpan-meta.sqlite');
my $sqlite = Mojo::SQLite->new->from_filename($sqlite_path);
$sqlite->migrations->from_data('main', 'cpan-meta')->migrate;

Mojo::IOLoop->next_tick(sub { prepare_database($sqlite) });
Mojo::IOLoop->recurring(ONE_HOUR() => sub { prepare_database($sqlite) });

helper 'sqlite' => sub { $sqlite };

get '/api/v1/packages/:module' => sub ($c) {
  my $module = $c->param('module');
  my $details = $c->sqlite->db->query('SELECT "package" AS "module", "version", "path" FROM "packages"
    WHERE "package" COLLATE NOCASE = ? ORDER BY "package" LIMIT 1', $module)->hashes->first;
  $c->reply->not_found unless defined $details;
  $c->render(json => $details);
};

get '/api/v1/perms/by-module/:module' => sub ($c) {
  my $module = $c->param('module');
  my $as_prefix = $c->param('as_prefix');
  my $where = '"package" COLLATE NOCASE = ?';
  my @params = ($module);
  if ($as_prefix) {
    $where = '"package" LIKE ? ESCAPE ?';
    @params = (($module =~ s/[%_]/\\$1/gr) . '%', '\\');
  }
  my $perms = $c->sqlite->db->query('SELECT "package" AS "module", "userid" AS "author", "best_permission" FROM "perms"
    WHERE ' . $where . ' ORDER BY "package", "userid"', @params)->hashes;
  $c->render(json => $perms);
};

get '/api/v1/perms/by-author/:author' => sub ($c) {
  my $author = $c->param('author');
  my $perms = $c->sqlite->db->query('SELECT "p"."userid" AS "author", "p"."package" AS "module", "p"."best_permission",
    (SELECT "userid" FROM "perms" WHERE "package"="p"."package" AND "best_permission"=? ORDER BY "userid" LIMIT 1) AS "owner"
    FROM "perms" AS "p" WHERE "userid" COLLATE NOCASE = ? ORDER BY "package"', 'f', $author)->hashes;
  $c->render(json => $perms);
};

app->start;

sub cache_file ($filename) {
  my $url = Mojo::URL->new(CPAN_MIRROR_METACPAN)->path("modules/$filename");
  my $local_path = $cache_dir->child($filename);
  my $res = $ua->mirror($url, $local_path);
  die "Failed to cache file from $url to $local_path: $res->{content}\n" if $res->{status} == 599;
  die "Failed to cache file from $url to $local_path: $res->{status} $res->{reason}\n" unless $res->{success};
  app->log->debug("Cached file from $url to $local_path: $res->{status} $res->{reason}");
  return $local_path;
}

sub inflate_file ($path) {
  my $unzipped_path = $path =~ s/\.gz\z//r;
  return $path if $path eq $unzipped_path;
  my $rc = gunzip("$path" => "$unzipped_path") or die "Failed to gunzip $path: $GunzipError\n";
  app->log->debug("Inflated $path to $unzipped_path");
  return $unzipped_path;
}

sub prepare_database ($sqlite) {
  Mojo::IOLoop->subprocess(sub {
    prepare_02packages($sqlite);
    prepare_06perms($sqlite);
  }, sub {
    my ($subprocess, $err, @results) = @_;
    if ($err) {
      app->log->error("Failed to prepare cpan-meta database: $err");
    } else {
      app->log->debug("Prepared cpan-meta database");
    }
  });
}

sub prepare_02packages ($sqlite) {
  my $packages_path = inflate_file(cache_file('02packages.details.txt.gz'));
  
  my $fh = fopen $packages_path, 'r';
  while (defined(my $line = readline $fh)) {
    last if $line =~ m/^\s*$/;
  }
  
  my $db = $sqlite->db;
  my $tx = $db->begin;
  $db->delete('packages');
  
  while (defined(my $line = readline $fh)) {
    my ($package, $version, $path) = split /\s+/, $line, 3;
    next unless length $version;
    $version = undef if $version eq 'undef';
    $db->insert('packages', {package => $package, version => $version, path => ($path // '')});
  }
  $tx->commit;
}

sub prepare_06perms ($sqlite) {
  my $perms_path = inflate_file(cache_file('06perms.txt.gz'));
  
  my $fh = fopen $perms_path, 'r';
  while (defined(my $line = readline $fh)) {
    last if $line =~ m/^\s*$/;
  }
  
  my $db = $sqlite->db;
  my $tx = $db->begin;
  $db->delete('perms');
  
  my $csv = Text::CSV_XS->new({binary => 1});
  $csv->bind_columns(\my $package, \my $userid, \my $best_permission);
  while ($csv->getline($fh)) {
    next unless length $package and length $userid and length $best_permission;
    unless ($best_permission eq 'm' or $best_permission eq 'f' or $best_permission eq 'c') {
      warn "06perms.txt: Found invalid permission type $best_permission for $userid on module $package\n";
      next;
    }
    $db->insert('perms', {package => $package, userid => $userid, best_permission => $best_permission});
  }
  $tx->commit;
}

__DATA__
@@ cpan-meta

-- 1 up
CREATE TABLE IF NOT EXISTS "packages" (
  "package" TEXT NOT NULL PRIMARY KEY,
  "version" TEXT NULL,
  "path" TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS "perms" (
  "id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  "package" TEXT NOT NULL,
  "userid" TEXT NOT NULL,
  "best_permission" TEXT NOT NULL CHECK ("best_permission" IN ('m','f','c'))
);
CREATE UNIQUE INDEX IF NOT EXISTS "perms_package_userid_unique_idx" ON "perms" ("package","userid");
CREATE INDEX IF NOT EXISTS "perms_userid_best_permission_idx" ON "perms" ("userid","best_permission");

-- 1 down
DROP TABLE IF EXISTS "packages";
DROP TABLE IF EXISTS "perms";
