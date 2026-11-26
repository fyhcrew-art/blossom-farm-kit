# Published programs of the Blossom farm kit

This branch holds no source code of the kit. It holds the programs the
kit's installers download, one folder per version of the patched GADS
provider (`GADS-drag`), each with its checksums, its complete source
archive, its build instructions and the licence texts. The kit itself is
on the branch `main`: <https://github.com/fyhcrew-art/blossom-farm-kit>.

Nothing here is meant to be downloaded by hand. The installers fetch a
program by the address of one exact commit of this branch and compare
its SHA-256 with the value pinned in the kit's `versions.json`.

The programs are a modified version of [GADS](https://github.com/shamanec/GADS),
licensed under the GNU AGPL v3.0. They were built on a maintainer's
computer with `tools/build-provider.sh` of the kit. The build is
reproducible: `BUILD.md` in each folder gives the commands, and anyone
who runs them gets files with the SHA-256 values of `SHA256SUMS`.

A program, once published, is never changed: a changed program gets a
new version and a new folder. What lies next to a program (the build
instructions, the source archive, the notices) can be corrected by a
later commit, which says so in its message; the programs and their
SHA-256 values stay as they are, and every earlier commit of this
branch keeps serving what it held.
