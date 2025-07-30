The [Module Index Search](https://cpanmeta.grinnz.com/packages) searches the
CPAN packages index, which is the file
[02packages.details.txt](https://www.cpan.org/modules/02packages.details.txt).
This is the canonical mapping of module name to the latest authorized stable
release of that module, maintained by PAUSE and used by CPAN installers when
given a module to install.

The [Permissions Search](https://cpanmeta.grinnz.com/perms) searches the PAUSE
permissions database, which is the file
[06perms.txt](https://www.cpan.org/modules/06perms.txt). This is the listing of
authors that can upload new stable releases of a module and have it indexed,
and that can modify the permissions for that module name. The `first-come`
permission, granted to the first user to upload a module name, has ultimate
authority on the name, and can add or remove any other user's permissions. The
`permission manager` permission can add or remove other `co-maint` permissions.
The `co-maint` permission can only remove their own permission. Note that these
module permissions are **not** hierarchical. An author must have permissions
for each individual module name they wish to have indexed.

The [Author Search](https://cpanmeta.grinnz.com/authors) searches the CPAN
authors database, which is the file
[00whois.xml](https://www.cpan.org/authors/00whois.xml). This contains
public details of the PAUSE accounts.

# PUBLIC INSTANCE

Public instance hosted at [https://cpanmeta.grinnz.com/](https://cpanmeta.grinnz.com/).

# API v2

See the [API documentation](api.html) for details.

# SOURCE CODE

The source code is hosted on [GitHub](https://github.com/Grinnz/cpan-meta-browser).

# COPYRIGHT AND LICENSE

This software is Copyright (c) 2017 by Dan Book `dbook@cpan.org`.

This is free software, licensed under:

> The Artistic License 2.0 (GPL Compatible)
