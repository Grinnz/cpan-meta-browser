package CPANMetaBrowser::Plugin::Backend::Redis;

# This software is Copyright (c) 2017 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Plugin';
use experimental 'signatures';
use Mojo::JSON qw(true false);
use Mojo::Redis2;

sub register ($self, $app, $config) {
  my $redis_url = $ENV{CPAN_META_BROWSER_REDIS_URL} // $app->config->{redis_url};
  my $redis = Mojo::Redis2->new(defined $redis_url ? (url => $redis_url) : ());
  
  $app->helper(redis => sub { $redis });
  
  $app->helper(get_packages => sub ($c, $module, $as_prefix = 0, $as_infix = 0) {
    return [] unless length $module;
    my $redis = $c->redis;
    my $packages_lc;
    if ($as_infix) {
      $packages_lc = $redis->zrangebylex('cpanmeta.packages_sorted', '-', '+');
      @$packages_lc = grep { m/\Q$module/i } @$packages_lc;
    } elsif ($as_prefix) {
      my $start = lc $module;
      my $end = $start =~ s/(.)\z/chr(ord($1)+1)/er;
      $packages_lc = $redis->zrangebylex('cpanmeta.packages_sorted', "[$start", "($end");
    } else {
      $packages_lc = $redis->zrangebylex('cpanmeta.packages_sorted', "[\L$module", "[\L$module");
    }
    my @package_names = @{$redis->hmget('cpanmeta.packages_lc', @$packages_lc)};
    my %package_map = map { ($packages_lc->[$_] => $package_names[$_]) } 0..$#$packages_lc;
    my @package_owners = @{$redis->hmget('cpanmeta.package_owners', @package_names)};
    my %owner_map = map { ($package_names[$_] => $package_owners[$_]) } 0..$#package_names;
    my $details = [];
    foreach my $package_lc (@$packages_lc) {
      my $package = $package_map{$package_lc} // next;
      my %package_details = @{$redis->hgetall("cpanmeta.package.$package")};
      my $owner = $owner_map{$package};
      push @$details, {
        module => $package_details{package},
        version => $package_details{version},
        path => $package_details{path},
        owner => $owner,
      };
    }
    ($_->{uploader}) = $_->{path} =~ m{^[^/]+/[^/]+/([a-z]+)}i for @$details;
    return $details;
  });
  
  $app->helper(existing_packages => sub ($c, $db) {
    return $db->smembers('cpanmeta.packages');
  });
  
  $app->helper(update_package => sub ($c, $db, $data) {
    my $current = {@{$db->hgetall("cpanmeta.package.$data->{package}")}};
    return 1 if $c->_keys_equal($data, $current, [qw(version path)]);
    my $tx = $db->multi;
    $tx->sadd('cpanmeta.packages', $data->{package});
    $tx->hmset("cpanmeta.package.$data->{package}", %$data);
    my $package_lc = lc $data->{package};
    $tx->hset('cpanmeta.packages_lc', $package_lc => $data->{package});
    $tx->zadd('cpanmeta.packages_sorted', 0 => $package_lc);
    $tx->exec;
  });
  
  $app->helper(delete_package => sub ($c, $db, $package) {
    my $tx = $db->multi;
    $tx->srem('cpanmeta.packages', $package);
    $tx->del("cpanmeta.package.$package");
    my $package_lc = lc $package;
    $tx->hdel('cpanmeta.packages_lc', $package_lc);
    $tx->zrem('cpanmeta.packages_sorted', $package_lc);
    $tx->exec;
  });
  
  $app->helper(get_perms => sub ($c, $author, $module = '', $as_prefix = 0, $as_infix = 0, $other_authors = 0) {
    return [] unless length $author or length $module;
    my $redis = $c->redis;
    my @userid_packages;
    if (length $author) {
      my ($userid_lc) = @{$redis->zrangebylex('cpanmeta.perms_userids_sorted', "[\L$author", "[\L$author")};
      return [] unless defined $userid_lc;
      my $userid = $redis->hget('cpanmeta.perms_userids_lc', $userid_lc) // return [];
      my $packages_lc;
      if (length $module) {
        if ($as_infix) {
          $packages_lc = $redis->zrangebylex("cpanmeta.perms_packages_for_userid.$userid", '-', '+');
          @$packages_lc = grep { m/\Q$module/i } @$packages_lc;
        } elsif ($as_prefix) {
          my $start = lc $module;
          my $end = $start =~ s/(.)\z/chr(ord($1)+1)/er;
          $packages_lc = $redis->zrangebylex("cpanmeta.perms_packages_for_userid.$userid", "[$start", "($end");
        } else {
          $packages_lc = $redis->zrangebylex("cpanmeta.perms_packages_for_userid.$userid", "[\L$module", "[\L$module");
        }
      } else {
        $packages_lc = $redis->zrangebylex("cpanmeta.perms_packages_for_userid.$userid", '-', '+');
      }
      my @package_names = @{$redis->hmget('cpanmeta.perms_packages_lc', @$packages_lc)};
      my %package_map = map { ($packages_lc->[$_] => $package_names[$_]) } 0..$#$packages_lc;
      my @package_owners = @{$redis->hmget('cpanmeta.package_owners', @package_names)};
      my %owner_map = map { ($package_names[$_] => $package_owners[$_]) } 0..$#package_names;
      foreach my $package_lc (@$packages_lc) {
        my $package = $package_map{$package_lc} // next;
        my $owner = $owner_map{$package};
        if ($other_authors) {
          my $userids_lc = $redis->zrangebylex("cpanmeta.perms_userids_for_package.$package", '-', '+');
          my @userids = @{$redis->hmget('cpanmeta.perms_userids_lc', @$userids_lc)};
          my %userid_map = map { ($userids_lc->[$_] => $userids[$_]) } 0..$#$userids_lc;
          push @userid_packages, map { [$userid_map{$_}, $package, $owner] } grep { defined $userid_map{$_} } @$userids_lc;
        } else {
          push @userid_packages, [$userid, $package, $owner];
        }
      }
    } else {
      my $packages_lc;
      if ($as_infix) {
        $packages_lc = $redis->zrangebylex('cpanmeta.perms_packages_sorted', '-', '+');
        @$packages_lc = grep { m/\Q$module/i } @$packages_lc;
      } elsif ($as_prefix) {
        my $start = lc $module;
        my $end = $start =~ s/(.)\z/chr(ord($1)+1)/er;
        $packages_lc = $redis->zrangebylex('cpanmeta.perms_packages_sorted', "[$start", "($end");
      } else {
        $packages_lc = $redis->zrangebylex('cpanmeta.perms_packages_sorted', "[\L$module", "[\L$module");
      }
      my @package_names = @{$redis->hmget('cpanmeta.perms_packages_lc', @$packages_lc)};
      my %package_map = map { ($packages_lc->[$_] => $package_names[$_]) } 0..$#$packages_lc;
      my @package_owners = @{$redis->hmget('cpanmeta.package_owners', @package_names)};
      my %owner_map = map { ($package_names[$_] => $package_owners[$_]) } 0..$#package_names;
      foreach my $package_lc (@$packages_lc) {
        my $package = $package_map{$package_lc} // next;
        my $owner = $owner_map{$package};
        my $userids_lc = $redis->zrangebylex("cpanmeta.perms_userids_for_package.$package", '-', '+');
        my @userids = @{$redis->hmget('cpanmeta.perms_userids_lc', @$userids_lc)};
        my %userid_map = map { ($userids_lc->[$_] => $userids[$_]) } 0..$#$userids_lc;
        push @userid_packages, map { [$userid_map{$_}, $package, $owner] } grep { defined $userid_map{$_} } @$userids_lc;
      }
    }
    my $perms = [];
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
  });
  
  $app->helper(existing_perms => sub ($c, $db) {
    return [map { +{userid => $_->[0], package => $_->[1]} } map { [split /\//, $_, 2] } @{$db->smembers('cpanmeta.perms')}];
  });
  
  $app->helper(update_perms => sub ($c, $db, $data) {
    my $current = {@{$db->hgetall("cpanmeta.perms.$data->{userid}/$data->{package}")}};
    return 1 if $c->_keys_equal($data, $current, ['best_permission']);
    my $tx = $db->multi;
    $tx->sadd('cpanmeta.perms', "$data->{userid}/$data->{package}");
    $tx->hmset("cpanmeta.perms.$data->{userid}/$data->{package}", %$data);
    $tx->hset('cpanmeta.package_owners', $data->{package} => $data->{userid}) if $data->{best_permission} eq 'f';
    my $package_lc = lc $data->{package};
    my $userid_lc = lc $data->{userid};
    $tx->hset('cpanmeta.perms_packages_lc', $package_lc => $data->{package});
    $tx->hset('cpanmeta.perms_userids_lc', $userid_lc => $data->{userid});
    $tx->zadd('cpanmeta.perms_packages_sorted', 0 => $package_lc);
    $tx->zadd('cpanmeta.perms_userids_sorted', 0 => $userid_lc);
    $tx->zadd("cpanmeta.perms_userids_for_package.$data->{package}", 0 => $userid_lc);
    $tx->zadd("cpanmeta.perms_packages_for_userid.$data->{userid}", 0 => $package_lc);
    $tx->exec;
  });
  
  $app->helper(delete_perms => sub ($c, $db, $userid, $packages) {
    my $tx = $db->multi;
    my $userid_lc = lc $userid;
    $tx->zrem("cpanmeta.perms_userids_for_package.$_", $userid_lc) for @$packages;
    $tx->zrem("cpanmeta.perms_packages_for_userid.$userid", map { lc } @$packages) if @$packages;
    $tx->exec;
    
    $tx = $db->multi;
    $tx->watch(
      (map { "cpanmeta.perms.$userid/$_" } @$packages),
      (map { "cpanmeta.perms_userids_for_package.$_" } @$packages),
      "cpanmeta.perms_packages_for_userid.$userid",
    );
    
    foreach my $package (@$packages) {
      $tx->srem('cpanmeta.perms', "$userid/$package");
      
      if (($db->hget("cpanmeta.perms.$userid/$package", 'best_permission') // '') eq 'f') {
        $tx->hdel('cpanmeta.package_owners', $package);
      }
      
      $tx->del("cpanmeta.perms.$userid/$package");
      
      my $package_lc = lc $package;
      unless ($db->zcard("cpanmeta.perms_userids_for_package.$package")) {
        $tx->hdel('cpanmeta.perms_packages_lc', $package_lc);
        $tx->zrem('cpanmeta.perms_packages_sorted', $package_lc);
      }
    }
    
    unless ($db->zcard("cpanmeta.perms_packages_for_userid.$userid")) {
      $tx->hdel('cpanmeta.perms_userids_lc', $userid_lc);
      $tx->zrem('cpanmeta.perms_userids_sorted', $userid_lc);
    }
    
    $tx->exec;
  });
  
  $app->helper(get_authors => sub ($c, $author, $as_prefix = 0, $as_infix = 0) {
    return [] unless length $author;
    my $redis = $c->redis;
    my $cpanids_lc;
    if ($as_infix) {
      $cpanids_lc = $redis->zrangebylex('cpanmeta.cpanids_sorted', '-', '+');
      @$cpanids_lc = grep { m/\Q$author/i } @$cpanids_lc;
    } elsif ($as_prefix) {
      my $start = lc $author;
      my $end = $start =~ s/(.)\z/chr(ord($1)+1)/er;
      $cpanids_lc = $redis->zrangebylex('cpanmeta.cpanids_sorted', "[$start", "($end");
    } else {
      $cpanids_lc = $redis->zrangebylex('cpanmeta.cpanids_sorted', "[\L$author", "[\L$author");
    }
    my @cpanids = @{$redis->hmget('cpanmeta.cpanids_lc', @$cpanids_lc)};
    my %cpanid_map = map { ($cpanids_lc->[$_] => $cpanids[$_]) } 0..$#$cpanids_lc;
    my $details = [];
    foreach my $cpanid_lc (@$cpanids_lc) {
      my $cpanid = $cpanid_map{$cpanid_lc} // next;
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
  });
  
  $app->helper(existing_authors => sub ($c, $db) {
    return $db->smembers('cpanmeta.authors');
  });
  
  $app->helper(update_author => sub ($c, $db, $data) {
    my $current = {@{$db->hgetall("cpanmeta.author.$data->{cpanid}")}};
    return 1 if $c->_keys_equal($data, $current, [qw(fullname asciiname email homepage introduced has_cpandir)]);
    my $tx = $db->multi;
    $tx->sadd('cpanmeta.authors', $data->{cpanid});
    $tx->hmset("cpanmeta.author.$data->{cpanid}", %$data);
    my $cpanid_lc = lc $data->{cpanid};
    $tx->hset('cpanmeta.cpanids_lc', $cpanid_lc => $data->{cpanid});
    $tx->zadd('cpanmeta.cpanids_sorted', 0 => $cpanid_lc);
    $tx->exec;
  });
  
  $app->helper(delete_author => sub ($c, $db, $cpanid) {
    my $tx = $db->multi;
    $tx->srem('cpanmeta.authors', $cpanid);
    $tx->del("cpanmeta.author.$cpanid");
    my $cpanid_lc = lc $cpanid;
    $tx->hdel('cpanmeta.cpanids_lc', $cpanid_lc);
    $tx->zrem('cpanmeta.cpanids_sorted', $cpanid_lc);
    $tx->exec;
  });
  
  $app->helper(get_refreshed => sub ($c, $type) {
    return $c->redis->hget('cpanmeta.refreshed', $type);
  });
  
  $app->helper(update_refreshed => sub ($c, $db, $type, $time) {
    $db->hset('cpanmeta.refreshed', $type => $time);
  });
}

1;
