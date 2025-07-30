# API v2

In addition to the browser interface, CPAN Meta Browser provides an API to the
contents of the files it indexes. The endpoints below are relative to the
installation path, such as [https://cpanmeta.grinnz.com/]. All endpoints
return JSON, and the module and author parameters are case insensitive and trim
surrounding whitespace.

## packages
```
GET /api/v2/packages/:module
GET /api/v2/packages/:module?as_prefix=1
GET /api/v2/packages/:module?as_infix=1
GET /api/v2/packages?module=:module&module=:module
```
Retrieves details from the CPAN module index for the specified module name. If
the `as_prefix` option is enabled, details are returned for all module names
starting with the specified prefix. If the `as_infix` option is enabled,
details are returned for all module names containing the specified infix.
Multiple module names may be specified as query parameters, but this will
disable prefix/infix matching.
```
# GET /api/v2/packages/Moose
{
   "data" : [
      {
         "module" : "Moose",
         "owner" : "STEVAN",
         "path" : "E\/ET\/ETHER\/Moose-2.2010.tar.gz",
         "uploader" : "ETHER",
         "version" : "2.2010"
      }
   ],
   "last_updated" : "1519669561"
}

# GET /api/v2/packages/Mojo::UserAgent?as_prefix=1
{
   "data" : [
      {
         "module" : "Mojo::UserAgent",
         "owner" : "SRI",
         "path" : "S\/SR\/SRI\/Mojolicious-7.69.tar.gz",
         "uploader" : "SRI","version":null
      },
      {
         "module" : "Mojo::UserAgent::Cached",
         "owner" : "NICOMEN",
         "path" : "N\/NI\/NICOMEN\/Mojo-UserAgent-Cached-1.06.tar.gz",
         "uploader" : "NICOMEN",
         "version" : "1.06"
      },
      ...
      {
         "module" : "Mojo::UserAgent::Transactor",
         "owner" : "SRI",
         "path" : "S\/SR\/SRI\/Mojolicious-7.69.tar.gz",
         "uploader" : "SRI",
         "version" : null
      }
   ],
   "last_updated" : "1519669561"
}

# GET /api/v2/packages?module=LWP&module=Mojo
{
  "data": [
    {
      "module": "LWP",
      "owner": "OALDERS",
      "path": "O/OA/OALDERS/libwww-perl-6.38.tar.gz",
      "uploader": "OALDERS",
      "version": "6.38"
    },
    {
      "module": "Mojo",
      "owner": "SRI",
      "path": "S/SR/SRI/Mojolicious-8.14.tar.gz",
      "uploader": "SRI",
      "version": null
    }
  ],
  "last_updated": 1556271962
}
```

## perms
```
GET /api/v2/perms?author=:author
GET /api/v2/perms?module=:module
GET /api/v2/perms?author=:author&module=:module&as_prefix=1&other_authors=1
GET /api/v2/perms?module=:module&as_infix=1
```
Retrieves details from the CPAN permissions database for the specified author
CPAN ID and/or module name. If the `as_prefix` option is enabled, details are
returned for all module names starting with the specified prefix. If the
`as_infix` option is enabled, details are returned for all module names
containing the specified infix. If the `other_authors` option is enabled,
details are returned for all authors with permissions for the matched modules,
not just the specified author CPAN ID.
```
# GET /api/v2/perms?author=LWWWP
{
   "data" : [
      {
         "author" : "LWWWP",
         "best_permission" : "f",
         "module" : "HTML::Entities",
         "owner" : "LWWWP"
      },
      {
         "author" : "LWWWP",
         "best_permission" : "c",
         "module" : "HTML::FormatMarkdown",
         "owner" : "NIGELM"
      },
      ...
      {
         "author" : "LWWWP",
         "best_permission" : "f",
         "module" : "WWW::RobotRules",
         "owner" : "LWWWP"
      }
   ],
   "last_updated" : "1519670202"
}

# GET /api/v2/perms?author=LWWWP&other_authors=1
{
   "data" : [
      {
         "author" : "ETHER",
         "best_permission" : "c",
         "module" : "HTML::Entities",
         "owner" : "LWWWP"
      },
      {
         "author" : "GAAS",
         "best_permission" : "c",
         "module" : "HTML::Entities",
         "owner" : "LWWWP"
      },
      ...
      {
         "author" : "MSTROUT",
         "best_permission" : "c",
         "module" : "WWW::RobotRules",
         "owner" : "LWWWP"
      }
   ],
   "last_updated" : "1519670202"
}

# GET /api/v2/perms?author=LWWWP&module=LWP::UserAgent
{
   "data" : [
      {
         "author" : "LWWWP",
         "best_permission" : "f",
         "module" : "LWP::UserAgent",
         "owner" : "LWWWP"
      }
   ],
   "last_updated" : "1519670202"
}

# GET /api/v2/perms?author=LWWWP&module=LWP::UserAgent&other_authors=1
{
   "data" : [
      {
         "author" : "ETHER",
         "best_permission" : "c",
         "module" : "LWP::UserAgent",
         "owner" : "LWWWP"
      },
      {
         "author" : "GAAS",
         "best_permission" : "c",
         "module" : "LWP::UserAgent",
         "owner" : "LWWWP"
      },
      ...
      {
         "author" : "OALDERS",
         "best_permission" : "c",
         "module" : "LWP::UserAgent",
         "owner" : "LWWWP"
      }
   ],
   "last_updated" : "1519670802"
}

# GET /api/v2/perms?module=LWP::UserAgent&as_prefix=1
{
   "data" : [
      {
         "author" : "ETHER",
         "best_permission" : "c",
         "module" : "LWP::UserAgent",
         "owner" : "LWWWP"
      },
      {
         "author" : "GAAS",
         "best_permission" : "c",
         "module" : "LWP::UserAgent",
         "owner" : "LWWWP"
      },
      ...
      {
         "author" : "SEKIMURA",
         "best_permission" : "f",
         "module" : "LWP::UserAgent::WithCache",
         "owner" : "SEKIMURA"
      }
   ],
   "last_updated" : "1519670802"
}
```

## authors
```
GET /api/v2/authors/:author
GET /api/v2/authors/:author?as_prefix=1
GET /api/v2/authors/:author?as_infix=1
```
Retrieves details from the CPAN author database for the specified author CPAN
ID. If the `as_prefix` option is enabled, details are returned for all author
CPAN IDs starting with the specified prefix. If the `as_infix` option is
enabled, details are returned for all author CPAN IDs containing the specified
infix.
```
# GET /api/v2/authors/DBOOK
{
   "data" : [
      {
         "asciiname" : null,
         "author" : "DBOOK",
         "email" : null,
         "fullname" : "Dan Book",
         "has_cpandir" : true,
         "homepage" : "http:\/\/github.com\/Grinnz",
         "introduced" : 1417016502
      }
   ],
   "last_updated" : "1519670892"
}

# GET /api/v2/authors/XA?as_prefix=1
{
   "data" : [
      {
         "asciiname" : null,
         "author" : "XACHEN",
         "email" : "...",
         "fullname" : "Justin Cassidy",
         "has_cpandir" : false,
         "homepage" : null,
         "introduced" : 1251852104
      },
      {
         "asciiname" : "Grzegorz Rozniecki",
         "author" : "XAERXESS",
         "email" : "...",
         "fullname" : "Grzegorz Rożniecki",
         "has_cpandir" : true,
         "homepage" : null,
         "introduced" : 1360005262
      },
      ...
      {
         "asciiname" : null,
         "author" : "XAXXON",
         "email" : "...",
         "fullname" : "Zac Hansen",
         "has_cpandir" : false,
         "homepage" : "http:\/\/xaxxon.slackworks.com\/",
         "introduced" : 1133035986
      }
   ],
   "last_updated" : "1519670892"
}
```

# COPYRIGHT AND LICENSE

This software is Copyright (c) 2017 by Dan Book `dbook@cpan.org`.

This is free software, licensed under:

> The Artistic License 2.0 (GPL Compatible)
