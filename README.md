sreq
====

As I recall...

Before we were allowed to push new code into Tru64 UNIX (nee Digital UNIX), we
had to file a submission request--called an srequest--with the release
engineering team. Filing an srequest involved a web form and lots of
boilerplate.

I worked on Ethernet drivers which were hosted in the "indep" pool, a repository
of sources that were internally conditionalized to build on multiple versions of
Tru64. For each driver fix, I'd have to file an srequest for the indep pool,
usually followed by six srequests, one for each of the versions between V4.0D
and V5.1B.

Having previously written `sqar` with @Chouser, I wrote `sreq` as a command-line
front end to the srequest web form. Its killer feature was the ability to
automatically duplicate the srequests for the multiple OS versions.

This repository contains the [original Perl script](./sreq.pl) and
the [later Ruby script](./sreq) for posterity.

See also https://github.com/agriffis-archive/sqar
