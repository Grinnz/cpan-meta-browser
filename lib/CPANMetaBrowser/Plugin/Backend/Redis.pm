package CPANMetaBrowser::Plugin::Backend::Redis;

# This software is Copyright (c) 2017 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use Mojo::JSON qw(to_json from_json true false);
use Mojo::Redis;

sub register ($self, $app, $config) {
  {
    my $redis_url = $ENV{CPAN_META_BROWSER_REDIS_URL} // $app->config->{redis_url};
    my $redis = Mojo::Redis->new($redis_url);
    
    $app->helper(redis => sub { $redis });
  }
  
  $app->helper(get_packages => sub ($c, $module, $as_prefix = 0, $as_infix = 0) {
    return [] unless length $module;
    my $db = $c->redis->db;
    my $packages_lc;
    if (ref $module eq 'ARRAY') {
      my %modules_map = map { (lc($_) => 1) } @$module;
      $packages_lc = $db->zrangebylex('cpanmeta.packages_sorted', '-', '+');
      @$packages_lc = grep { exists $modules_map{$_} } @$packages_lc;
    } elsif ($as_infix) {
      $packages_lc = $db->zrangebylex('cpanmeta.packages_sorted', '-', '+');
      @$packages_lc = grep { m/\Q$module/i } @$packages_lc;
    } elsif ($as_prefix) {
      my $start = lc $module;
      my $end = $start =~ s/(.)\z/chr(ord($1)+1)/er;
      $packages_lc = $db->zrangebylex('cpanmeta.packages_sorted', "[$start", "($end");
    } else {
      $packages_lc = $db->zrangebylex('cpanmeta.packages_sorted', "[\L$module", "[\L$module");
    }
    return [] unless @$packages_lc;
    my @package_names = @{$db->hmget('cpanmeta.packages_lc', @$packages_lc)};
    my %package_map = map { ($packages_lc->[$_] => $package_names[$_]) } 0..$#$packages_lc;
    my @package_owners = @{$db->hmget('cpanmeta.package_owners', @package_names)};
    my %owner_map = map { ($package_names[$_] => $package_owners[$_]) } 0..$#package_names;
    my @package_details = @{$db->hmget('cpanmeta.package_data', @package_names)};
    my %details_map = map { ($package_names[$_] => $package_details[$_]) } 0..$#package_names;
    my $details = [];
    foreach my $package_lc (@$packages_lc) {
      my $package = $package_map{$package_lc} // next;
      my $package_details = from_json($details_map{$package} || 'null');
      my $owner = $owner_map{$package};
      push @$details, {
        module => $package_details->{package},
        version => $package_details->{version},
        path => $package_details->{path},
        owner => $owner,
      };
    }
    ($_->{uploader}) = $_->{path} =~ m{^[^/]+/[^/]+/([a-z]+)}i for @$details;
    return $details;
  });
  
  $app->helper(existing_packages => sub ($c, $db) {
    return $db->hkeys('cpanmeta.package_data');
  });
  
  $app->helper(update_package => sub ($c, $db, $data) {
    my $current = from_json($db->hget('cpanmeta.package_data', $data->{package}) || 'null');
    return 1 if $c->_keys_equal($data, $current, [qw(version path)]);
    $db->multi;
    $db->hset('cpanmeta.package_data', $data->{package} => to_json $data);
    my $package_lc = lc $data->{package};
    $db->hset('cpanmeta.packages_lc', $package_lc => $data->{package});
    $db->zadd('cpanmeta.packages_sorted', 0 => $package_lc);
    $db->exec;
  });
  
  $app->helper(delete_package => sub ($c, $db, $package) {
    $db->multi;
    $db->hdel('cpanmeta.package_data', $package);
    my $package_lc = lc $package;
    $db->hdel('cpanmeta.packages_lc', $package_lc);
    $db->zrem('cpanmeta.packages_sorted', $package_lc);
    $db->exec;
  });
  
  $app->helper(get_perms => sub ($c, $author, $module = '', $as_prefix = 0, $as_infix = 0, $other_authors = 0) {
    return [] unless length $author or length $module;
    my $db = $c->redis->db;
    my @userid_packages;
    if (length $author) {
      my ($userid_lc) = @{$db->zrangebylex('cpanmeta.perms_userids_sorted', "[\L$author", "[\L$author")};
      return [] unless defined $userid_lc;
      my $userid = $db->hget('cpanmeta.perms_userids_lc', $userid_lc) // return [];
      my $packages_lc;
      if (length $module) {
        if ($as_infix) {
          $packages_lc = $db->zrangebylex("cpanmeta.perms_packages_for_userid.$userid", '-', '+');
          @$packages_lc = grep { m/\Q$module/i } @$packages_lc;
        } elsif ($as_prefix) {
          my $start = lc $module;
          my $end = $start =~ s/(.)\z/chr(ord($1)+1)/er;
          $packages_lc = $db->zrangebylex("cpanmeta.perms_packages_for_userid.$userid", "[$start", "($end");
        } else {
          $packages_lc = $db->zrangebylex("cpanmeta.perms_packages_for_userid.$userid", "[\L$module", "[\L$module");
        }
      } else {
        $packages_lc = $db->zrangebylex("cpanmeta.perms_packages_for_userid.$userid", '-', '+');
      }
      my @package_names = @{$db->hmget('cpanmeta.perms_packages_lc', @$packages_lc)};
      my %package_map = map { ($packages_lc->[$_] => $package_names[$_]) } 0..$#$packages_lc;
      my @package_owners = @{$db->hmget('cpanmeta.package_owners', @package_names)};
      my %owner_map = map { ($package_names[$_] => $package_owners[$_]) } 0..$#package_names;
      foreach my $package_lc (@$packages_lc) {
        my $package = $package_map{$package_lc} // next;
        my $owner = $owner_map{$package};
        if ($other_authors) {
          my $userids_lc = $db->zrangebylex("cpanmeta.perms_userids_for_package.$package", '-', '+');
          my @userids = @{$db->hmget('cpanmeta.perms_userids_lc', @$userids_lc)};
          my %userid_map = map { ($userids_lc->[$_] => $userids[$_]) } 0..$#$userids_lc;
          push @userid_packages, map { [$userid_map{$_}, $package, $owner] } grep { defined $userid_map{$_} } @$userids_lc;
        } else {
          push @userid_packages, [$userid, $package, $owner];
        }
      }
    } else {
      my $packages_lc;
      if ($as_infix) {
        $packages_lc = $db->zrangebylex('cpanmeta.perms_packages_sorted', '-', '+');
        @$packages_lc = grep { m/\Q$module/i } @$packages_lc;
      } elsif ($as_prefix) {
        my $start = lc $module;
        my $end = $start =~ s/(.)\z/chr(ord($1)+1)/er;
        $packages_lc = $db->zrangebylex('cpanmeta.perms_packages_sorted', "[$start", "($end");
      } else {
        $packages_lc = $db->zrangebylex('cpanmeta.perms_packages_sorted', "[\L$module", "[\L$module");
      }
      my @package_names = @{$db->hmget('cpanmeta.perms_packages_lc', @$packages_lc)};
      my %package_map = map { ($packages_lc->[$_] => $package_names[$_]) } 0..$#$packages_lc;
      my @package_owners = @{$db->hmget('cpanmeta.package_owners', @package_names)};
      my %owner_map = map { ($package_names[$_] => $package_owners[$_]) } 0..$#package_names;
      foreach my $package_lc (@$packages_lc) {
        my $package = $package_map{$package_lc} // next;
        my $owner = $owner_map{$package};
        my $userids_lc = $db->zrangebylex("cpanmeta.perms_userids_for_package.$package", '-', '+');
        my @userids = @{$db->hmget('cpanmeta.perms_userids_lc', @$userids_lc)};
        my %userid_map = map { ($userids_lc->[$_] => $userids[$_]) } 0..$#$userids_lc;
        push @userid_packages, map { [$userid_map{$_}, $package, $owner] } grep { defined $userid_map{$_} } @$userids_lc;
      }
    }
    my @perms_details = @{$db->hmget('cpanmeta.perms_data', map { "$_->[0]/$_->[1]" } @userid_packages)};
    my %details_map;
    $details_map{$userid_packages[$_][0]}{$userid_packages[$_][1]} = $perms_details[$_] for 0..$#userid_packages;
    my $perms = [];
    foreach my $userid_package (@userid_packages) {
      my ($userid, $package, $owner) = @$userid_package;
      my $perms_details = from_json($details_map{$userid}{$package} || 'null');
      push @$perms, {
        author => $perms_details->{userid},
        module => $perms_details->{package},
        best_permission => $perms_details->{best_permission},
        owner => $owner,
      };
    }
    return $perms;
  });
  
  $app->helper(existing_perms => sub ($c, $db) {
    return [map { +{userid => $_->[0], package => $_->[1]} } map { [split /\//, $_, 2] } @{$db->hkeys('cpanmeta.perms_data')}];
  });
  
  $app->helper(update_perms => sub ($c, $db, $data) {
    my $current = from_json($db->hget('cpanmeta.perms_data', "$data->{userid}/$data->{package}") || 'null');
    return 1 if $c->_keys_equal($data, $current, ['best_permission']);
    $db->multi;
    $db->hset('cpanmeta.perms_data', "$data->{userid}/$data->{package}" => to_json $data);
    $db->hset('cpanmeta.package_owners', $data->{package} => $data->{userid}) if $data->{best_permission} eq 'f';
    my $package_lc = lc $data->{package};
    my $userid_lc = lc $data->{userid};
    $db->hset('cpanmeta.perms_packages_lc', $package_lc => $data->{package});
    $db->hset('cpanmeta.perms_userids_lc', $userid_lc => $data->{userid});
    $db->zadd('cpanmeta.perms_packages_sorted', 0 => $package_lc);
    $db->zadd('cpanmeta.perms_userids_sorted', 0 => $userid_lc);
    $db->zadd("cpanmeta.perms_userids_for_package.$data->{package}", 0 => $userid_lc);
    $db->zadd("cpanmeta.perms_packages_for_userid.$data->{userid}", 0 => $package_lc);
    $db->exec;
  });
  
  $app->helper(delete_perms => sub ($c, $db, $userid, $packages) {
    $db->multi;
    my $userid_lc = lc $userid;
    $db->zrem("cpanmeta.perms_userids_for_package.$_", $userid_lc) for @$packages;
    $db->zrem("cpanmeta.perms_packages_for_userid.$userid", map { lc } @$packages) if @$packages;
    $db->exec;
    
    $db->watch(
      'cpanmeta.perms_data',
      (map { "cpanmeta.perms_userids_for_package.$_" } @$packages),
      "cpanmeta.perms_packages_for_userid.$userid",
    );
    
    my @perms_details = @{$db->hmget('cpanmeta.perms_data', map { "$userid/$_" } @$packages)};
    my %details_map = map { ($packages->[$_] => $perms_details[$_]) } 0..$#$packages;
    my %has_package_map = map { ($_ => $db->zcard("cpanmeta.perms_userids_for_package.$_")) } @$packages;
    my $has_userid = $db->zcard("cpanmeta.perms_packages_for_userid.$userid");
    
    $db->multi;
    
    foreach my $package (@$packages) {
      my $details = from_json($details_map{$package} || 'null');
      if (($details->{best_permission} // '') eq 'f') {
        $db->hdel('cpanmeta.package_owners', $package);
      }
      
      $db->hdel('cpanmeta.perms_data', "$userid/$package");
      
      my $package_lc = lc $package;
      unless ($has_package_map{$package}) {
        $db->hdel('cpanmeta.perms_packages_lc', $package_lc);
        $db->zrem('cpanmeta.perms_packages_sorted', $package_lc);
      }
    }
    
    unless ($has_userid) {
      $db->hdel('cpanmeta.perms_userids_lc', $userid_lc);
      $db->zrem('cpanmeta.perms_userids_sorted', $userid_lc);
    }
    
    $db->exec;
  });
  
  $app->helper(get_authors => sub ($c, $author, $as_prefix = 0, $as_infix = 0) {
    return [] unless length $author;
    my $db = $c->redis->db;
    my $cpanids_lc;
    if ($as_infix) {
      $cpanids_lc = $db->zrangebylex('cpanmeta.cpanids_sorted', '-', '+');
      @$cpanids_lc = grep { m/\Q$author/i } @$cpanids_lc;
    } elsif ($as_prefix) {
      my $start = lc $author;
      my $end = $start =~ s/(.)\z/chr(ord($1)+1)/er;
      $cpanids_lc = $db->zrangebylex('cpanmeta.cpanids_sorted', "[$start", "($end");
    } else {
      $cpanids_lc = $db->zrangebylex('cpanmeta.cpanids_sorted', "[\L$author", "[\L$author");
    }
    my @cpanids = @{$db->hmget('cpanmeta.cpanids_lc', @$cpanids_lc)};
    my %cpanid_map = map { ($cpanids_lc->[$_] => $cpanids[$_]) } 0..$#$cpanids_lc;
    my @author_details = @{$db->hmget('cpanmeta.author_data', @cpanids)};
    my %details_map = map { ($cpanids[$_] => $author_details[$_]) } 0..$#cpanids;
    my $details = [];
    foreach my $cpanid_lc (@$cpanids_lc) {
      my $cpanid = $cpanid_map{$cpanid_lc} // next;
      my $author = from_json($details_map{$cpanid} || 'null');
      push @$details, {
        author => $author->{cpanid},
        fullname => $author->{fullname},
        asciiname => $author->{asciiname},
        email => $author->{email},
        homepage => $author->{homepage},
        introduced => $author->{introduced},
        has_cpandir => $author->{has_cpandir},
      };
    }
    $_->{has_cpandir} = $_->{has_cpandir} ? true : false for @$details;
    return $details;
  });
  
  $app->helper(existing_authors => sub ($c, $db) {
    return $db->hkeys('cpanmeta.author_data');
  });
  
  $app->helper(update_author => sub ($c, $db, $data) {
    my $current = from_json($db->hget('cpanmeta.author_data', $data->{cpanid}) || 'null');
    return 1 if $c->_keys_equal($data, $current, [qw(fullname asciiname email homepage introduced has_cpandir)]);
    $db->multi;
    $db->hset('cpanmeta.author_data', $data->{cpanid} => to_json $data);
    my $cpanid_lc = lc $data->{cpanid};
    $db->hset('cpanmeta.cpanids_lc', $cpanid_lc => $data->{cpanid});
    $db->zadd('cpanmeta.cpanids_sorted', 0 => $cpanid_lc);
    $db->exec;
  });
  
  $app->helper(delete_author => sub ($c, $db, $cpanid) {
    $db->multi;
    $db->hdel('cpanmeta.author_data', $cpanid);
    my $cpanid_lc = lc $cpanid;
    $db->hdel('cpanmeta.cpanids_lc', $cpanid_lc);
    $db->zrem('cpanmeta.cpanids_sorted', $cpanid_lc);
    $db->exec;
  });
  
  $app->helper(get_refreshed => sub ($c, $type) {
    return $c->redis->db->hget('cpanmeta.refreshed', $type);
  });
  
  $app->helper(update_refreshed => sub ($c, $db, $type, $time) {
    $db->hset('cpanmeta.refreshed', $type => $time);
  });
}

1;
