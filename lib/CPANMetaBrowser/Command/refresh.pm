package CPANMetaBrowser::Command::refresh;

# This software is Copyright (c) 2017 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
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

1;
