#!/usr/bin/env perl

# Copyright (C) Yichun Zhang (agentzh)

use v5.10.1;
use strict;
use warnings;

use Encode qw( decode );
use FindBin ();
use File::Find ();
use File::Path qw( make_path );
use File::Spec ();
use Config ();
use Cwd qw( realpath cwd );
use Digest::MD5 ();
use File::Copy qw( copy move );
use File::Temp qw( tempfile );
use Getopt::Long qw( GetOptions :config no_ignore_case require_order);
#use Data::Dumper qw( Dumper );

my $MAX_DEPS = 100;
my $Version = '0.0.1';

my ($TarBall, $RepoLink, $RepoLinkUser, @Licenses, $LuaJIT, $LockFile);

my $UserAgent = "opm $Version ($Config::Config{archname}, perl $^V)";

my %Licenses = (
    apache2 => 'Apache License 2.0',
    '3bsd' => 'BSD 3-Clause "New" or "Revised" license',
    '2bsd' => 'BSD 2-Clause "Simplified" or "FreeBSD" license',
    gpl => 'GNU General Public License (GPL)',
    gpl2 => 'GNU General Public License (GPL) version 2',
    gpl3 => 'GNU General Public License (GPL) version 3',
    lgpl => 'GNU Library or "Lesser" General Public License (LGPL)',
    mit => 'MIT license',
    mozilla2 => 'Mozilla Public License 2.0',
    cddl => 'Common Development and Distribution License',
    eclipse => 'Eclipse Public License',
    public => 'Public Domain',
    artistic => 'Artistic License',
    artistic2 => 'Artistic License 2.0',
    proprietary => 'Proprietary',
);

my $SpecialDepPat = qr/^(?:openresty|luajit|ngx_(?:http_)?lua|nginx)$/;

sub err (@);
sub shell ($);
sub find_sys_install_dir ();
sub get_install_dir ();
sub install_file ($$$);
sub install_target ($$);
sub upgrade_target ($$$$);
sub remove_target ($$$);
sub do_build ($);
sub check_lock_file ();
sub get_rc_file ();
sub create_stub_rc_file ($);
sub read_ini ($);
sub init_installation_ctx ($);
sub cmp_version ($$);
sub search_pkg_name ($$);
sub test_version_spec ($$$$$);
sub check_utf8_field ($$$);
sub check_user_file_path ($$$$);
sub rebase_path ($$$);

GetOptions("h|help",          \(my $help),
           "cwd",             \(my $install_into_cwd),
           "verbose",         \(my $verbose))
   or usage(1);

if ($help) {
    usage(0);
}

my $cmd = shift or
    err "no command specified.\n";

if ($cmd eq '-v') {
    print "opm $Version ($Config::Config{archname}, perl $^V)\n";
    exit;
}

# explicitly clear the environments to avoid breaking luajit and resty.
delete $ENV{LUA_PATH};
delete $ENV{LUA_CPATH};

for ($cmd) {
    if ($_ eq 'get' || $_ eq 'install') {
        check_lock_file();

        do_get(@ARGV);

    } elsif ($_ eq 'build') {
        do_build(0);

    } elsif ($_ eq 'server-build') {
        do_build(1);

    } elsif ($_ eq 'upload') {
        check_lock_file();

        do_build(0);
        do_upload();

    } elsif ($_ eq 'remove' || $_ eq 'uninstall') {
        check_lock_file();

        do_remove(@ARGV);

    } elsif ($_ eq 'list') {
        do_list();

    } elsif ($_ eq 'info') {
        do_info(@ARGV);

    } elsif ($_ eq 'upgrade') {
        do_upgrade(@ARGV);

    } elsif ($_ eq 'update') {
        do_update();

    } elsif ($_ eq 'search') {
        do_search(@ARGV);

    } elsif ($_ eq 'clean') {
        do_clean(@ARGV);

    } else {
        warn "ERROR: unknown command: $cmd\n\n";
        usage(1);
    }
}

END {
    if (defined $LockFile) {
        unlink $LockFile
            or err "failed to remove the lock file $LockFile: $!\n";

        undef $LockFile;
    }
}

sub do_get {
    if (@_ == 0) {
        err "no packages specified for fetch.\n";
    }

    my $deps = parse_deps(\@_, "(command-line argument)", 1);

    #warn Dumper($deps);

    my $ctx = init_installation_ctx(0);

    for my $dep (@$deps) {
        install_target($ctx, $dep);
    }
}

sub do_build ($) {
    my $server_build = shift;

    #if ($server_build) { while (1) {} }

    if (!defined $LuaJIT) {
        $LuaJIT = find_luajit();
    }

    my $account;
    if (!$server_build) {
        my ($rcfile, $data) = get_rc_file();
        my $default_sec = $data->{default};
        $account = delete $default_sec->{github_account};
        if (!$account) {
            err "$rcfile: no \"github_account\" specified.\n";
        }
    }

    my $dist_file = "dist.ini";
    my $data = read_ini($dist_file);

    #warn Dumper($data);

    my $default_sec = delete $data->{default};

    my $dist_name = delete $default_sec->{name};
    if (!$dist_name) {
        err "$dist_file: key \"name\" not found in the default section.\n";
    }

    if (length $dist_name < 3
        || $dist_name =~ /[^-\w]|^(?:nginx|luajit|resty|openresty|opm|restydoc.*|ngx_.*|.*-nginx-module)$/i)
    {
        err "$dist_file: bad dist name: $dist_name\n";
    }

    if ($server_build) {
        $account = delete $default_sec->{account}
            or err "$dist_file: key \"account\" not found in the default section.\n";
    }

    my $author = delete $default_sec->{author};
    if (!$author) {
        err "$dist_file: key \"author\" not found in the default section.\n";
    }

    check_utf8_field($dist_file, 'author', $author);

    my @authors = split /\s*,\s*/, $author;
    if (grep { !defined || !/[a-zA-Z]/ } @authors) {
        err "$dist_file: bad value in the \"author\" field of the default section: $author\n";
    }

    my $is_original = delete $default_sec->{is_original};
    if (!$is_original) {
        err "$dist_file: key \"is_original\" not found in the default section.\n";
    }

    if ($is_original !~ /^(?:yes|no)$/) {
        err "$dist_file: bad value in the \"is_original\" field of the ",
            "default section: $is_original (only \"yes\" or \"no\" are allowed)\n";
    }

    my $license = delete $default_sec->{license};
    if (!$license) {
        err "$dist_file: key \"license\" not found in the default section.\n";
    }

    my @licenses = split /\s*,\s*/, $license;
    my @license_descs;

    for my $item (@licenses) {
        my $license_desc = $Licenses{$item};
        if (!$license_desc) {
            err "$dist_file: unknown license value: $item\n",
                "    (only the following license values are recognized: ",
                join(" ", sort keys %Licenses), ")\n";
        }
        push @license_descs, $license_desc;
    }

    @Licenses = @licenses;

    warn "found license: ", join(", ", @license_descs), ".\n";

    my $dist_abstract = delete $default_sec->{abstract};
    if (!$dist_abstract) {
        err "$dist_file: key \"abstract\" not found in the default section.\n";
    }

    check_utf8_field($dist_file, 'abstract', $dist_abstract);

    my $repo_link = delete $default_sec->{repo_link};
    if (!$repo_link) {
        err "$dist_file: key \"repo_link\" not found in the default section.\n";
    }

    if ($repo_link !~ m{^https?://}g) {
        err "$dist_file: bad \"repo_link\" value ",
            "(must be a http:// or https:// link): $repo_link\n";
    }

    if ($repo_link =~ /["'\s<>{}]/s) {
        err "$dist_file: bad \"repo_link\" value: $repo_link\n";
    }

    if ($repo_link =~ m{\bgithub\.com\b}s) {
        if ($repo_link !~ m{github\.com/([^/\s]+)/([^/\s]+)}) {
            err "$dist_file: bad GitHub repo link: $repo_link\n";
        }

        my $user = $1;
        my $proj = $2;
        if ($proj ne $dist_name) {
            err "$dist_file: project \"$proj\" in repo_link ",
                "\"$repo_link\" does not match name \"$dist_name\".\n";
        }

        $RepoLinkUser = $user;
        $RepoLink = $repo_link;
    }

    if ($repo_link =~ /[[:^ascii:]]/s) {
        err "$dist_file: repo_link contains non-ASCII characters.\n";
    }

    if ($repo_link =~ /[[:^print:]]/s) {
        err "$dist_file: repo_link contains non-printable characters.\n";
    }

=begin comment

    if (!$server_build) {
        my $out = `curl -sS -I $repo_link 2>&1`;
        if ($out =~ m{^ HTTP/1\.\d \s+ (\d+) \b}ix) {
            my $status = $1;
            if ($status >= 400) {
                err "$dist_file: bad repo_link $repo_link: ",
                    "got HTTP status code $status.\n";
            }
        } else {
            err "$dist_file: bad repo_link $repo_link: $out\n";
        }
    }

=end comment

=cut

    my $version = delete $default_sec->{version};

    if ($server_build && !$version) {
            err "$dist_file: \"version\" field not defined in the default section.\n";
    }

    if ($version) {
        if ($version !~ /\d/ || $version =~ /[^.\w]/) {
            err "$dist_file: bad version number: $version\n";
        }
    }

    my $deps;
    my $requires = delete $default_sec->{requires};

    if ($requires) {
        $deps = parse_deps($requires, $dist_file);
        my $ndeps = @$deps;
        if ($ndeps >= $MAX_DEPS) {
            err "$dist_file: requires: too many dependencies: $ndeps\n";
        }

        if (!$server_build) {
            my $ctx = init_installation_ctx(0);
            $ctx->{level} = 1;

            for my $dep (@$deps) {
                install_target($ctx, $dep);
            }
        }
    }

    my @exclude_files;
    my $exclude = delete $default_sec->{exclude_files};
    if ($exclude) {
        my @pats = grep { $_ } split /\s*,\s*/, $exclude;
        for my $pat (@pats) {
            my @f = glob $pat;
            if (!@f) {
                err "$dist_file: exclude_files pattern \"$pat\" ",
                    "does not match any files.\n";
            }
            push @exclude_files, @f;
        }
    }

    my $lib_dir = delete $default_sec->{lib_dir};

    if ($server_build && $lib_dir ne 'lib') {
        err "$dist_file: \"lib_dir\" must be \"lib\".\n";
    }

    if ($lib_dir) {
        check_user_file_path($dist_file, "lib_dir", $lib_dir, 'd');

    } else {
        $lib_dir = 'lib';
        if (!-d $lib_dir) {
            err "default lib_dir \"lib/\" not found.\n";
        }
    }

    my $user_main_module = delete $default_sec->{main_module};
    if ($user_main_module) {
        check_user_file_path($dist_file, "main_module", $user_main_module, 'f');
    }

    # process Lua module files.

    my $main_module;
    my @lua_modules;

    File::Find::find({ no_chdir => 1, wanted => sub {
        return unless /\.lua$/;

        my $full_name = $File::Find::name;

        if ($full_name =~ /\b$dist_name-\d+/) {
            return;
        }

        for my $file (@exclude_files) {
            #warn "$full_name vs $file";
            if (realpath($full_name) eq realpath($file)) {
                warn "excluded file $full_name due to \"exclude_files\".\n";
                return;
            }
        }

        (my $name = $full_name) =~ s{^\Q$lib_dir\E/?}{};
        $name =~ s{/}{-}g;
        $name =~ s/\.(\w+)$//;

        my $module = {
            path => $File::Find::name,
            name => $name,
        };

        if (!$user_main_module && $dist_name =~ /\Q$name\E$/) {
            if (!$main_module
                || length $main_module->{name} > length $name)
            {
                $main_module = $module;
            }
        }

        #warn $name;
        push @lua_modules, $module;
    } },  $lib_dir);

    if (!@lua_modules) {
        err "No Lua modules found under direcgtory $lib_dir.\n";
    }

    if (!$user_main_module) {
        if (!$main_module) {
            @lua_modules = sort { $a->{name} cmp $b->{name} } @lua_modules;
            my $first = $lua_modules[0];
            $main_module = $first;
        }
    }

    if ($user_main_module) {
        $main_module = $user_main_module;

    } else {
        $main_module = $main_module->{path};
        warn "derived main_module file $main_module\n";
    }

    open my $in, $main_module
        or err "cannot open main_module file $main_module for reading: $!\n";

    my $code_ver;
    while (<$in>) {
        if (/\b(?:_?VERSION|version)\s*=\s*(\S+)/) {
            (my $ver = $1) =~ s/[;,'"{}()<>]|\[=*\[|\]=*\]|\s+$//g;
            if ($ver =~ /\d/) {
                $code_ver = $ver;
                last;
            }
        }
    }

    close $in;

    if ($code_ver) {
        warn "extracted verson number $code_ver from main_module file $main_module.\n";

        if (!$version) {
            $version = $code_ver;
        } elsif ($version ne $code_ver) {
            err "version $version defined in $dist_file does not match ",
                "version $code_ver defined in main_module file $main_module.\n";
        }

    }  elsif (!$version) {
        err "verson not defined in $dist_file or in main_module file $main_module.\n";
    }

    # check Lua source file syntax.

    for my $mod (@lua_modules) {
        shell "$LuaJIT -b '$mod->{path}' /dev/null";
    }

    # copy document files over.

    my $doc_dir = delete $default_sec->{doc_dir};

    if ($server_build && $doc_dir ne 'lib') {
        err "$dist_file: \"doc_dir\" must be \"lib\".\n";
    }

    if (%$default_sec) {
        my @keys = sort keys %$default_sec;
        err "$dist_file: unrecognized keys under the default section: @keys.\n";
    }

    if (%$data) {
        my @keys = sort keys %$data;
        err "$dist_file: unrecognized section names: @keys.\n";
    }

    my $root_dir = "$dist_name-$version";

    if ($server_build) {
        $root_dir .= ".opm";
    }

    if (-d $root_dir) {
        shell "rm -rf './$root_dir'";
    }

    my $dst_lib_dir = File::Spec->catfile($root_dir, "lib");
    make_path($dst_lib_dir);

    if ($server_build) {
        my $restydoc_index = find_restydoc_index();
        shell "$restydoc_index --outdir '$root_dir' .";
    }

    for my $mod (@lua_modules) {
        my $src = $mod->{path};
        my $dst = rebase_path($src, $lib_dir, $dst_lib_dir);

        (my $dir = $dst) =~ s{[^/]*$}{}g;
        if ($dir && !-d $dir) {
            make_path($dir);
        }

        #warn $dst;
        copy($src, $dst)
            or err "failed to copy $src to $dst: $!\n";
    }

    # process docs

    my @module_docs;

    if ($doc_dir) {
        check_user_file_path($dist_file, "doc_dir", $doc_dir, 'd');

    } else {
        $doc_dir = 'lib';
        if (!-d $doc_dir) {
            err "default doc_dir \"lib/\" not found.\n";
        }
    }

    File::Find::find({ no_chdir => 1, wanted => sub {
        return unless /\.(md|markdown|pod)$/;
        my $ext = $1;

        my $full_name = $File::Find::name;

        if ($full_name =~ /\b$dist_name-\d+/) {
            return;
        }

        for my $file (@exclude_files) {
            if (realpath($full_name) eq realpath($file)) {
                warn "excluded file $full_name due to \"exclude_files\".\n";
                return;
            }
        }

        (my $fname = $File::Find::name) =~ s{^\Q$lib_dir\E/?}{};

        push @module_docs, {
            path => $File::Find::name,
            fname => $fname,
        };

        #warn "$fname => $File::Find::name";
    } },  $doc_dir);

    if (!$server_build) {
        my $dst_doc_dir = File::Spec->catfile($root_dir, "lib");
        make_path($dst_doc_dir);

        for my $mod (@module_docs) {
            my $fname = $mod->{fname};
            my $src = $mod->{path};
            my $dst = File::Spec->catfile($dst_doc_dir, $fname);
            (my $dir = $dst) =~ s{[^/]*$}{}g;
            if ($dir && !-d $dir) {
                make_path($dir);
            }

            #warn $dst;
            copy($src, $dst)
                or err "failed to copy $src to $dst: $!\n";
        }
    }

    {
        my $found_readme;
        my @files = (glob('*.md'), glob('*.markdown'), glob('*.pod'));
        for my $file (@files) {
            if ($file =~ /^(readme|changes)\.(\w+)$/i) {
                my ($basename, $ext) = (lc $1, $2);

                if ($basename eq 'readme') {
                    $basename = 'README';
                    $found_readme = 1;

                } elsif ($basename eq 'changes') {
                    $basename = 'Changes';
                }

                my $dst = File::Spec->catfile($root_dir, "$basename.$ext");
                copy($file, $dst)
                    or err "failed to copy $file to $dst: $!\n";
                next;
            }

            if ($file =~ /^(?:COPYING|COPYRIGHT)$/i) {
                my $new_file = uc $file;
                my $dst = File::Spec->catfile($root_dir, $new_file);

                copy($file, $dst)
                    or err "failed to copy $file to $dst: $!\n";
                next;
            }
        }

        if (!$found_readme) {
            err "could not found README.md or README.pod.\n";
        }
    }

    $main_module = rebase_path($main_module, $lib_dir, 'lib')
        or err "$dist_file: cannot rewrite $main_module from $lib_dir to lib/";

    {
        my $outfile = "$root_dir/dist.ini";
        open my $out, ">$outfile"
            or err "failed to open $outfile for writing: $!\n";

        print $out <<_EOC_;
account = $account
name = $dist_name
abstract = $dist_abstract
author = $author
is_original = $is_original
license = $license
repo_link = $repo_link
lib_dir = lib
doc_dir = lib
version = $version
main_module = $main_module
_EOC_

        if ($requires) {
            print $out "requires = $requires\n";
        }

        close $out;
    }

    $TarBall = "$root_dir.tar.gz";
    shell "tar -cvzf '$TarBall' '$root_dir'";

    #if ($server_build) {
    #err "something bad bad bad.\n";
    #}
}

sub read_ini ($) {
    my $infile = shift;
    open my $in, $infile
        or err "cannot open $infile for reading: $!\n";

    my %sections;
    my $sec_name = 'default';
    my $sec = ($sections{$sec_name} = {});

    local $_;
    while (<$in>) {
        next if /^\s*$/ || /^\s*[\#;]/;

        if (/^ \s* (\w+) \s* = \s* (.*)/x) {
            my ($key, $val) = ($1, $2);
            $val =~ s/\s+$//;
            if (exists $sec->{$key}) {
                err "$infile: line $.: duplicate key in section ",
                    "\"$sec_name\": $key\n";
            }
            $sec->{$key} = $val;
            next;
        }

        if (/^ \s* \[ \s* ([^\]]*) \] \s* $/x) {
            my $name = $1;
            $name =~ s/\s+$//;
            if ($name eq '') {
                err "$infile: line $.: section name empty.\n";
            }

            if (exists $sections{$name}) {
                err "$infile: line $.: section \"$name\" redefined.\n";
            }

            $sec = {};
            $sections{$name} = $sec;
            $sec_name = $name;

            next;
        }

        err "$infile: line $.: syntax error: $_";
    }

    close $in;

    return \%sections;
}

sub parse_deps {
    my ($line, $file, $relax) = @_;

    my @items;
    if (ref $line) {
        @items = @$line;

    } else {
        @items = split /\s*,\s*/, $line;
    }

    my @parsed;
    for my $item (@items) {
        if ($item =~ m{^ ([-/\w]+) $}x) {
            my $full_name = $item;

            my ($account, $name);

            if ($full_name =~ m{^ ([-\w]+) / ([-\w]+)  }x) {
                ($account, $name) = ($1, $2);

            } elsif ($full_name =~ $SpecialDepPat) {
                $name = $full_name;

            } else {
                if (!$relax) {
                    err "$file: bad dependency name: $full_name\n";
                }

                $name = $full_name;
            }

            push @parsed, [$account, $name];

        } elsif ($item =~ m{^ ([-/\w]+) \s* ([^\w\s]+) \s* (\w\S*) $}x) {
            my ($full_name, $op, $ver) = ($1, $2, $3);

            my ($account, $name);

            if ($full_name =~ m{^ ([-\w]+) / ([-\w]+)  }x) {
                ($account, $name) = ($1, $2);

            } elsif ($full_name =~ $SpecialDepPat) {
                $name = $full_name;

            } else {
                err "$file: bad dependency name: $full_name\n";
            }

            if ($op !~ /^ (?: >= | = | > ) $/x) {
                err "$file: bad dependency version comparison",
                    " operator in \"$item\": $op\n";
            }

            if ($ver !~ /\d/ || $ver =~ /[^-.\w]/) {
                err "$file: bad version number in dependency",
                    " specification in \"$item\": $ver\n";
            }

            push @parsed, [$account, $name, $op, $ver];

        } else {
            err "$file: bad dependency specification: $item\n";
        }
    }

    @parsed = sort { $a->[1] cmp $b->[1] } @parsed;
    return \@parsed;
}

sub do_upload {
    if (! grep { $_ ne 'proprietary' } @Licenses) {
        # TODO we may allow this for custom package servers in the future.
        err "uploading proprietary code is prohibited.\n";
    }

    my ($rcfile, $data) = get_rc_file();

    my $default_sec = delete $data->{default};

    my $account = delete $default_sec->{github_account};
    if (!$account) {
        err "$rcfile: no \"github_account\" specified.\n";
    }

    if ($account !~ /^[-\w]+$/) {
        err "$rcfile: bad \"github_account\" value: $account\n";
    }

    if (defined $RepoLinkUser && $RepoLinkUser ne $account) {
        err "$rcfile: github_account \"$account\" does not match the ",
            "github account \"$RepoLinkUser\" in repo_link $RepoLink in dist.ini.\n";
    }

    my $token = delete $default_sec->{github_token};
    if (!$token) {
        err "$rcfile: no \"github_token\" specified.\n";
    }

    if ($token !~ /^[a-f0-9]{40}$/i) {
        err "$rcfile: bad \"github_token\" value: $token\n";
    }

    my $upload_url = delete $default_sec->{upload_server};
    if (!$upload_url) {
        err "$rcfile: no upload_server specified.\n";
    }

    if ($upload_url !~ m{^https?://}) {
        err "$rcfile: the value of upload_server must be ",
            "led by https:// or http://.\n";
    }

    $upload_url =~ s{/+$}{};

    my $download_url = delete $default_sec->{download_server};
    if (!$download_url) {
        err "$rcfile: no download_server specified.\n";
    }

    if ($download_url !~ m{^https?://}) {
        err "$rcfile: the value of download_server must be ",
            "led by https:// or http://.\n";
    }

    if (%$default_sec) {
        my @keys = sort keys %$default_sec;
        err "$rcfile: unrecognized keys under the default section: @keys.\n";
    }

    if (%$data) {
        my @keys = sort keys %$data;
        err "$rcfile: unrecognized section names: @keys.\n";
    }

    my $md5sum;
    {
        open my $in, $TarBall
            or err "cannot open $TarBall for reading: $!\n";
        my $ctx = Digest::MD5->new;
        $ctx->addfile($in);
        #$ctx->add("foo");
        $md5sum = $ctx->hexdigest;
        close $in;
    }

    # upload the tar ball to the package server with the github access token.

    # TODO we should migrate from curl to a Lua script via the resty utility.
    shell("curl " . ($verbose ? "-vv " : "") . "-sS -i -A '$UserAgent'"
          . " -H 'X-File: $TarBall' -H 'X-File-Checksum: $md5sum'"
          . " -H 'X-Account: $account' -H 'X-Token: $token'"
          . " -T '$TarBall' '$upload_url/api/pkg/upload'");
}

sub find_luajit {
    my $lj = realpath(
                File::Spec->catfile(
                    $FindBin::RealBin, "../luajit/bin/luajit"));

    if (!defined $lj || !-f $lj || !-x $lj) {
        return 'luajit';
    }

    return $lj;
}

sub find_restydoc_index {
    my $fname = "restydoc-index";
    my $file = realpath(
                    File::Spec->catfile(
                        $FindBin::RealBin, $fname));

    if (!defined $file || !-f $file || !-x $file) {
        return $fname;
    }

    return $file;
}

sub create_stub_rc_file ($) {
    my $rcfile = shift;

    # create a stub
    open my $out, ">$rcfile"
        or err "cannot open $rcfile for writing: $!\n";
    print $out <<_EOC_;
# your github account name (either your github user name or github organization that you owns)
github_account=

# you can generate a github personal access token from the web UI: https://github.com/settings/tokens
# IMPORTANT! you are required to assign the scopes "user:email" and "read:org" to your github token.
# you should NOT assign any other scopes to your token due to security considerations.
github_token=

# the opm central server for uploading openresty packages.
upload_server=https://opm.openresty.org

# the opm server for downloading openresty packages.
download_server=https://opm.openresty.org
_EOC_
    close $out;

    chmod 0600, $rcfile
        or err "$rcfile: failed to chmod to 0600: $!\n";
}

sub get_rc_file () {
    my $home = $ENV{HOME};
    if (!$home) {
        err "environment HOME not defined.\n";
    }

    my $rcfile = File::Spec->catfile($home, ".opmrc");
    if (!-f $rcfile) {
        create_stub_rc_file($rcfile);
    }

    return ($rcfile, read_ini($rcfile));
}

sub check_lock_file () {
    # TODO when we support the --cwd option, we should use a lock file in the
    # current working directory instead, like ./resty_modules/lock

    if (!$ENV{HOME}) {
        err "no HOME system environment defined.\n";
    }

    my $opmdir = File::Spec->catdir($ENV{HOME}, ".opm");
    if (!-d $opmdir) {
        make_path $opmdir;
    }

    my $lockfile = File::Spec->catfile($opmdir, "lock");
    if (-f $lockfile) {
        open my $in, $lockfile or
            lock_hold_err($lockfile);

        my $pid = <$in>;
        close $in;

        if (!$pid) {
            lock_hold_err($lockfile);

        } else {
            if (!kill 0, $pid) {
                my $err = $!;
                if ($err =~ /No such process/i) {
                    #warn "the lock holder is already gone; ",
                         #"simply remove the lock file";

                    unlink $lockfile
                        or err "failed to remove the lockfile hold by the ",
                               "process with PID $pid ",
                               "(which is already gone): $!\n";

                } else {
                    lock_hold_err($lockfile, $pid);
                }

            } else {
                lock_hold_err($lockfile, $pid);
            }
        }
    }

    {
        open my $out, ">$lockfile"
            or err "failed to create the lock file $lockfile: $!\n";
        print $out $$;
        close $out;

        $LockFile = $lockfile;
    }
}

sub lock_hold_err {
    my ($file, $pid) = @_;

    err "Found the lock file $file hold by another opm process",
        $pid ? "(PID $pid)" : "", ".\n";
}

sub install_target ($$) {
    my ($ctx, $target_spec) = @_;

    my ($account, $name, $op, $ver) = @$target_spec;

    if (!$account) {
        if ($ctx->{level} == 0) {
            if ($name =~ $SpecialDepPat) {
                err "you cannot install $name via opm.\n";
            }

            warn "ERROR: package name $name is not prefixed by ",
                 "an account name.\nFinding candidates...\n";
            search_pkg_name($ctx, $name);
            return;
        }

        # nested, resolved as a true dependency.

        if ($name =~ $SpecialDepPat) {
            my $resty = $ctx->{resty};

            if ($name eq 'luajit') {
                my $out = `$resty -e 'print(jit.version)'`;
                if ($? != 0 || !defined $out || $out !~ /^LuaJIT (\d+\.\d+\.\d+)/) {
                    err "$name is required but is not available ",
                        "according to $resty: ", $out // '', "\n";
                }

                my $luajit_ver = $1;
                test_version_spec($name, $luajit_ver, $op, $ver, $resty);
                return;
            }

            if ($name eq 'nginx') {
                my $out = `$resty -e 'print(ngx.config.nginx_version)'`;
                if ($? != 0 || !defined $out || $out !~ /^(\d+)(\d{3})(\d{3})$/) {
                    err "$name is required but is not available ",
                        "according to $resty: ", $out // '', "\n";
                }

                my $nginx_ver = join ".", $1 + 0, $2 + 0, $3 + 0;
                #die "nginx version: $nginx_ver";
                test_version_spec($name, $nginx_ver, $op, $ver, $resty);
                return;
            }

            if ($name =~ /^ngx_(?:http_)?lua$/) {
                my $out = `$resty -e 'print(ngx.config.ngx_lua_version)'`;
                if ($? != 0 || !defined $out || $out !~ /^(\d{4,})$/) {
                    err "$name is required but is not available ",
                        "according to $resty: ", $out // '', "\n";
                }

                my $v = $1;
                my $v1 = $v % 1000;
                my $tmp = int($v / 1000);
                my $v2 = $tmp % 1000;
                $tmp = int($tmp / 1000);
                my $v3 = $tmp % 1000;

                my $ngx_lua_ver = "$v3.$v2.$v1";
                #die "ngx_lua version: $ngx_lua_ver";
                test_version_spec($name, $ngx_lua_ver, $op, $ver, $resty);
                return;
            }

            if ($name eq 'openresty') {
                my $out = `$resty -v 2>&1`;
                if ($? != 0 || !defined $out || $out !~ m!\bopenresty/(\d+(?:\.\d+){3})!) {
                    err "$name is required but is not available ",
                        "according to $resty: ", $out // '', "\n";
                }

                my $openresty_ver = $1;
                #die "openresty version: $openresty_ver";
                test_version_spec($name, $openresty_ver, $op, $ver, $resty);
                return;
            }

            die "unknown name: $name";

        } else {
            err "bad package name; you must specify an account prefix, ",
                "like \"openresty/lua-resty-lrucache\".\n"
        }
    }

    if ($ctx->{pkg_installing}{"$account/$name"}) {
        err "cyclic dependency chain detected when installing the package $account/$name\n";
    }

    my $manifest_dir = $ctx->{manifest_dir} or die;
    my $meta_file = File::Spec->catfile($manifest_dir, "$name.meta");
    my $installed_ver;
    my $remove_old;

    {
        if (-f $meta_file) {
            my $data = read_ini($meta_file);
            my $default_sec = $data->{default};

            my $meta_account = $default_sec->{account}
                or err "$meta_file: key \"account\" not found.\n";

            my $v = $default_sec->{version}
                or err "$meta_file: key \"version\" not found.\n";

            if ($meta_account ne $account) {
                err "failed to install $account/$name: ",
                    "$meta_account/$name $v already installed.\n";
            }

            $installed_ver = $v;

            my $skip_install;

            if (!defined $ver || !defined $op) {
                goto SKIP_INSTALL;
            }

            if ($op eq '>=') {
                if (cmp_version($ver, $v) > 0) {
                    #warn "upgrading $account/$name from $v ...\n";
                    $remove_old = 1;

                } else {
                    # already installed and version is good
                    goto SKIP_INSTALL;
                }

            } elsif ($op eq '>') {
                if (cmp_version($ver, $v) >= 0) {
                    #warn "upgrading $account/$name from $v ...\n";
                    $remove_old = 1;

                } else {
                    # already installed and version is good
                    goto SKIP_INSTALL;
                }

            } else {
                # $op eq '='

                if (cmp_version($ver, $v) == 0) {
                    # already installed and version is good
                    goto SKIP_INSTALL;
                }

                $remove_old = 1;
            }
        }
    }

    my ($op_arg, $ver_arg);
    if (defined $op) {
        if ($op eq '>') {
            $op_arg = 'gt';

        } elsif ($op eq '>=') {
            $op_arg = 'ge';

        } elsif ($op eq '=') {
            $op_arg = 'eq';

        } else {
            err "bad version comparison operator: $op.\n";
        }

    } else {
        $op_arg = '';
    }

    if (!$ver) {
        $ver_arg = '';

    } else {
        $ver_arg = $ver;
    }

    my $download_url = $ctx->{download_url};

    my $url = qq{$download_url/api/pkg/fetch?}
              . qq{account=$account\&name=$name\&op=$op_arg\&version=$ver_arg};

    if (!defined $op) {
        $op = '';
    }
    warn "* Fetching $account/$name $op $ver_arg\n";

    my $cmd = qq/curl -sS -i -A '$UserAgent' '$url'/;
    my $out = `$cmd`;
    if ($? != 0) {
        err "failed to run command \"$cmd\"\n";
    }

    if (!$out) {
        err "no response received from server for URL \"$url\".\n";
    }

    my $expected_md5;

    #warn "out: $out";

    open my $in, "<", \$out or die $!;
    my $status_line = <$in>;
    if ($status_line !~ m{^ HTTP/\d+\.\d+ \s+ (\d+) \b }x) {
        err "bad response status line received from server for URL \"$url\".\n";
    }

    my $status = $1;
    #warn $status;
    if ($status eq '404') {
        my ($found_body);
        my $body = '';
        while (<$in>) {
            if ($found_body) {
                $body .= $_;
                next;
            }

            if (/^\r?$/) {
                $found_body = 1;
                next;
            }
        }

        $body =~ s/\n+//gs;

        my $spec = ($op && $ver) ? " $op $ver" : "";

        if ($ctx->{upgrade}) {
            warn "Package $account/$name $ver is already the latest version.\n";
            return;
        }

        err "failed to find package $account/$name$spec: $body\n";
    }

    if ($status ne '302') {
        err "unexpected server response status code for URL \"$url\": $status\n";
    }

    my ($found_body, $target, $dist_file);
    while (<$in>) {
        if (/^\r?$/) {
            $found_body = 1;
            last;
        }

        #warn $_;

        if (/^ X-File-Checksum \s* : \s* (\S+) /ix) {
            $expected_md5 = $1;
            $expected_md5 =~ s/-//g;
            if ($expected_md5 !~ /^[a-f0-9]{32}$/) {
                err "bad file checksum received from server URL ",
                    "\"$url\": $expected_md5\n";
            }
            next;
        }

        if (/^Location \s* : \s* (\S+) /xi) {
            $target = $1;
            if ($target !~ m{^/api/pkg/tarball/$account/($name-\S+?\.opm\.tar\.gz)$}) {
                err "bad 302 redirect target in the server response: $target\n";
            }

            $dist_file = $1;
            next;
        }
    }

    close $in or die $!;

    if (!$target) {
        err "found no Location header in server response: $out";
    }

    if (!defined $expected_md5) {
        err "no X-File-Checksum response header received from server URL ",
            "\"$url\": $out\n";
    }

    $url = $download_url . $target;

    my $cache_dir = $ctx->{cache_dir};

    my $cache_subdir = File::Spec->catdir($cache_dir, $account);
    if (!-d $cache_subdir) {
        File::Path::make_path($cache_subdir);
    }

    my $dist_file_path = File::Spec->catfile($cache_subdir, $dist_file);

    my $header_file = $ctx->{header_file};

    warn "  Downloading $url\n";
    shell "curl -A '$UserAgent' -o '$dist_file_path' -D '$header_file' '$url'";

    open $in, $header_file or
        err "failed to open $header_file for reading: $!\n";

    $status_line = <$in>;
    if ($status_line !~ m{^ HTTP/\d+\.\d+ \s+ (\d+) \b }x) {
        err "bad response status line received from server for URL \"$url\".\n";
    }

    $status = $1;

    close $in or err "failed to close file $header_file: $!";

    #warn $status;
    if ($status ne '200') {
        err "failed to fetch $dist_file: server returns bad status code $status.\n";
    }

    if (!-f $dist_file_path) {
        err "$dist_file_path not found.\n";
    }

    my $cwd = cwd;
    chdir $cache_subdir
        or err "cannot chdir to $cache_subdir: $!\n";

    my $actual_md5;
    {
        open my $in, $dist_file
            or err "cannot open $dist_file for reading: $!\n";
        my $ctx = Digest::MD5->new;
        $ctx->addfile($in);
        #$ctx->add("foo");
        $actual_md5 = $ctx->hexdigest;
        close $in;
    }

    if ($actual_md5 ne $expected_md5) {
        err "File downloaded might be corrupted or truncated ",
            "because the checksums do not match: ",
            "$actual_md5 vs $expected_md5\n";
    }

    (my $dist_dir = $dist_file) =~ s/\.tar\.gz$//;

    if (-d $dist_dir) {
        shell "rm -rf '$dist_dir'";
    }

    shell "tar -xzf '$dist_file'";

    if (!-d $dist_dir) {
        err "the unpacked directory $dist_dir not found under $cache_subdir.\n";
    }

    chdir $dist_dir
        or err "cannot chdir to $cache_subdir/$dist_dir: $!\n";

    # read dist.ini

    my $ini_file = "dist.ini";
    my $data = read_ini($ini_file);

    my $default_sec = $data->{default};

    my $version = $default_sec->{version}
        or err "$dist_dir: no version found in $ini_file\n";

    if (!-d 'lib') {
        err "no lib/ found in $dist_dir/.\n"
    }

    if (!-d 'pod') {
        err "no pod/ found in $dist_dir/.\n"
    }

    my $restydoc_index = 'resty.index';
    if (!-f $restydoc_index) {
        err "no $restydoc_index file found in $dist_dir/.\n";
    }

    my $requires = $default_sec->{requires};
    if ($requires) {
        my $deps = parse_deps($requires, $ini_file);

        $ctx->{pkg_installing}{"$account/$name"} = 1;

        $ctx->{level}++;

        for my $dep (@$deps) {
            install_target($ctx, $dep);
        }

        $ctx->{level}--;

        delete $ctx->{pkg_installing}{"$account/$name"};
    }

    my @lua_files;
    File::Find::find(sub {
        return unless -f $_;
        my $src_path = $File::Find::name;
        (my $target_path = $src_path) =~ s{^lib/}{};
        push @lua_files, [$src_path, $target_path],
    },  'lib');

    if (!@lua_files) {
        err "no library files found in $dist_dir/.\n";
    }

    if ($remove_old) {
        remove_target($ctx, $name, undef);
    }

    my $installed_files = $ctx->{installed_files};

    for my $spec (@lua_files) {
        my ($src, $dst) = @$spec;

        my $file = File::Spec->catfile("lualib", $dst);
        my $pkg = $installed_files->{$file};
        if ($pkg) {
            err "file $dst in package $account/$name already appears ",
                "in the previously installed package $pkg.\n";
        }
        $installed_files->{$file} = "$name";
    }

    my @pod_files;
    File::Find::find(sub {
        return unless -f $_;
        my $src_path = $File::Find::name;
        (my $target_path = $src_path) =~ s{^pod/}{};
        push @pod_files, [$src_path, $target_path],
    },  'pod');

    if (!@pod_files) {
        err "no document files found in $dist_dir/.\n";
    }

    my $install_dir = $ctx->{install_dir} or die;
    my $lualib_dir = $ctx->{lualib_dir} or die;

    for my $spec (@lua_files) {
        my ($src, $dst) = @$spec;

        install_file($src, $dst, $lualib_dir);
    }

    my $pod_dir = $ctx->{pod_dir} or die;

    for my $spec (@pod_files) {
        my ($src, $dst) = @$spec;

        install_file($src, $dst, $pod_dir);
    }

    my $list_file = File::Spec->catfile($manifest_dir, "$name.list");

    {
        open my $out, ">$list_file"
            or err "failed to write to $list_file: $!\n";

        for my $spec (@lua_files) {
            my ($src, $dst) = @$spec;
            my $file = File::Spec->catfile("lualib", $dst);
            print $out $file, "\n";
        }

        for my $spec (@pod_files) {
            my ($src, $dst) = @$spec;
            print $out File::Spec->catfile("pod", $dst), "\n";
        }

        close $out;
    }

    install_file($ini_file, "$name.meta", $manifest_dir);

    # install resty.index

    my $installed_restydoc_index = File::Spec->catfile($install_dir, "resty.index");

    {
        open my $out, ">>$installed_restydoc_index"
            or err "failed to open $installed_restydoc_index for appending: $!\n";

        open my $in, $restydoc_index
            or err "$dist_dir: failed to open $restydoc_index for reading: $!\n";

        print $out "# BEGIN $name\n\n";

        while (<$in>) {
            print $out $_;
        }

        print $out "# END $name\n";

        close $in;
        close $out;

    }

    warn "Package $account/$name $version installed successfully ",
         "under $install_dir/ .\n";

    chdir $cwd
        or err "cannot chdir to $cwd: $!\n";

    return;

SKIP_INSTALL:

    warn "Package $name-$installed_ver already installed.\n";
    return;
}

sub get_install_dir () {
    if (defined $install_into_cwd) {
        my $dir = File::Spec->catdir(cwd(), "resty_modules");
        if (!-d $dir) {
            make_path $dir;
        }
        return $dir;
    }

    return find_sys_install_dir();
}

sub find_sys_install_dir () {
    my $path = File::Spec->catdir($FindBin::RealBin, "..", "site");
    my $dir = realpath($path);

    if (!defined $dir || !-d $dir) {
        err "cannot find OpenResty system installation directory ",
            "($path not found).\n";
    }

    return $dir;
}

sub install_file ($$$) {
    my ($src, $dst, $install_dir) = @_;

    my $dst_path = File::Spec->catfile($install_dir, $dst);

    if (-f $dst_path) {
        # FIXME maybe we should not override existing files by default?

        unlink $dst_path
            or err "destination file path $dst_path already exists and ",
                   "cannot be removed: $!\n";
    }

    if (-d $dst_path) {
        err "destination file path $dst_path already exists ",
            "and is a directory.\n";
    }

    (my $dir = $dst_path) =~ s{(.*)/[^/]+$}{$1};

    if (!-d $dir) {
        make_path $dir;
    }

    copy($src, $dst_path) or err "failed to copy $src to $dst_path: $!\n";
}

sub cmp_version ($$) {
    my ($a, $b) = @_;

    my @a = split /\D+/, $a;
    my @b = split /\D+/, $b;

    for (my $i = 0; $i < @a; $i++) {
        my $x = $a[$i];
        my $y = $b[$i];

        if (!defined $x && !defined $y) {
            return 0;
        }

        if (defined $x && defined $y) {
            my $val = ($x <=> $y);
            if ($val == 0) {
                next;
            }
            return $val;
        }

        if (defined $x) {
            return 1;
        }

        return -1;
    }

    return 0;
}

sub remove_target ($$$) {
    my ($ctx, $name, $account) = @_;

    my $install_dir = $ctx->{install_dir};
    if (!defined $install_dir) {
        err "cannot find OpenResty system installation directory.\n";
    }

    #warn $install_dir;

    my $cwd = cwd;
    chdir $install_dir or err "cannot chdir to $install_dir: $!\n";

    my $manifest_dir = "manifest";
    if (!-d $manifest_dir) {
        err "package $account/$name not installed yet.\n";
    }

    my $meta_file = File::Spec->catfile($manifest_dir, "$name.meta");

    #warn $meta_file;

    my $version;
    if (-f $meta_file) {
        my $data = read_ini($meta_file);

        my $default_sec = $data->{default};
        my $meta_account = $default_sec->{account};

        if ($account) {
            if ($account ne $meta_account) {
                err "package $account/$name not installed yet ",
                    "(but $meta_account/$name already installed).\n";
            }

        } else {
            $account = $meta_account;
        }

        $version = $default_sec->{version};
    }

    my $restydoc_index = "resty.index";
    if (-f $restydoc_index) {
        open my $in, $restydoc_index
            or err "cannot open $restydoc_index for reading: $!\n";

        my ($tmp, $tmp_fname) = tempfile("opm-XXXXXXX",
                                         TMPDIR => 1, UNLINK => 1);

        my ($skipping, $found);
        while (<$in>) {
            if ($skipping) {
                if (/^# END \Q$name\E$/) {
                    undef $skipping;
                }

                next;
            }

            if (/^# BEGIN \Q$name\E$/) {
                $found = 1;
                $skipping = 1;
                next;
            }

            print $tmp $_;
        }

        close $tmp;

        close $in;

        if ($found) {
            move($tmp_fname, $restydoc_index)
                or err "failed to move $tmp_fname to $restydoc_index: $!\n";

        } else {
            unlink $tmp_fname;  # ignore any errors here.
        }
    }

    my $list_file = File::Spec->catfile($manifest_dir, "$name.list");
    my ($found_list, $found_meta);

    my %dirs;

    if (-f $list_file) {
        $found_list = 1;

        open my $in, $list_file
            or err "failed to open $list_file for reading: $!\n";

        my $installed_files = $ctx->{installed_files} or die;

        while (<$in>) {
            chomp;

            if (m{(.+)/}) {
                my $dir = $1;
                if ($dir =~ m{\S/\S}) {
                    $dirs{$dir} = 1;
                }
            }

            delete $installed_files->{$_};

            unlink or warn "WARNING: failed to remove file $_: $!\n";
        }
        close $in;

        unlink $list_file
            or warn "WARNING: failed to remove file $list_file: $!\n";

        for my $dir (reverse sort keys %dirs) {
            rmdir $dir;  # we ignore any errors here...
        }

    } elsif (-f $meta_file) {
        warn "file $list_file is missing.\n";
    }

    if (-f $meta_file) {
        $found_meta = 1;

        unlink $meta_file
            or warn "WARNING: failed to remove file $meta_file: $!\n";

    } elsif ($found_list) {
        warn "file $meta_file is missing.\n";
    }

    if (!$found_list && !$found_meta) {
        err "package $name not installed yet.\n";
    }

    warn "Package $account/$name $version removed successfully.\n";

    chdir $cwd or err "cannot chdir to $install_dir";
}

sub do_remove {
    if (@_ == 0) {
        err "no packages specified for removal.\n";
    }

    my $deps = parse_deps(\@_, "(command-line argument)", 1);

    my $ctx = init_installation_ctx(0);

    for my $dep (@$deps) {
        my ($account, $name, $op, $ver) = @$dep;

        if ($op && $ver) {
            warn "ignoring version constraint $op $ver ...\n";
        }

        remove_target($ctx, $name, $account);
    }
}

sub do_list {
    my $install_dir = get_install_dir();

    my $manifest_dir = File::Spec->catfile($install_dir, "manifest");
    if (!-d $manifest_dir) {
        return;
    }

    opendir my $dh, $manifest_dir
        or err "failed to open directory $manifest_dir: $!\n";

    while (my $entry = readdir $dh) {
        #warn $entry;
        if ($entry =~ /(.+)\.meta$/) {
            my $pkg = $1;

            my $file = File::Spec->catfile($manifest_dir, $entry);

            my $data = read_ini($file);
            my $default_sec = $data->{default};

            my $version = $default_sec->{version}
                or err "$file: no version found for package $pkg.\n";

            my $account = $default_sec->{account}
                or err "$file: no account found for package $pkg.\n";

            printf "%-60s %s\n", "$account/$pkg", $version;
        }
    }

    closedir $dh
        or err "failed to close directory $manifest_dir: $!\n";
}

sub do_info {
    if (@_ == 0) {
        err "no packages specified for info.\n";
    }

    my $install_dir = get_install_dir();

    my $manifest_dir = File::Spec->catfile($install_dir, "manifest");
    if (!-d $manifest_dir) {
        err "no packages installed yet.\n";
    }

    local $_;
    for (@_) {
        my ($account, $name);

        if (m{^ ([-\w]+) / ([-\w]+) $}x) {
            ($account, $name) = ($1, $2);

        } elsif (m{^ ([-\w]+) }x) {
            $name = $1;

        } else {
            err "bad package name: $_\n";
        }

        my $meta_file = File::Spec->catfile($manifest_dir, "$name.meta");
        if (!-f $meta_file) {
            err "package $name not installed yet.\n";
        }

        my $data = read_ini $meta_file;
        my $default_sec = $data->{default};

        my $meta_account = $default_sec->{account}
            or err "$meta_file: key \"account\" not found.\n";

        if ($account && $meta_account ne $account) {
            err "package $account/$name not installed ",
                "(but $meta_account/$name installed).\n";
        }

        my $license = $default_sec->{license}
            or err "$meta_file: key \"license\" not found.\n";

        my @licenses = split /\s*,\s*/, $license;
        my $license_lines = '';
        my $i = 0;
        for my $l (@licenses) {
            my $desc = $Licenses{$l} || 'Unknown';
            if ($i == 0) {
                $license_lines .= $desc;

            } else {
                $license_lines .= ",\n                 : $desc";
            }

        } continue {
            $i++;
        }

        print <<_EOC_;
Name             : $name
Version          : $default_sec->{version}
Abstract         : $default_sec->{abstract}
Author           : $default_sec->{author}
Account          : $meta_account
Code Repo        : $default_sec->{repo_link}
License          : $license_lines
Original Work    : $default_sec->{is_original}
_EOC_

        my $requires = $default_sec->{requires};
        if ($requires) {
            print <<_EOC_;
Requires         : $requires
_EOC_
        }
    }
}

sub do_upgrade {
    if (@_ == 0) {
        err "no packages specified for upgrade.\n";
    }

    my $ctx = init_installation_ctx(1);
    my $manifest_dir = $ctx->{manifest_dir};

    local $_;
    for (@_) {
        my ($account, $name);

        if (m{^ ([-\w]+) / ([-\w]+) $}x) {
            ($account, $name) = ($1, $2);

        } elsif (m{^ ([-\w]+) }x) {
            $name = $1;

        } else {
            err "bad package name: $_\n";
        }

        my $meta_file = File::Spec->catfile($manifest_dir, "$name.meta");
        upgrade_target($ctx, $account, $name, $meta_file);
    }
}

sub init_installation_ctx ($) {
    my $upgrade = shift;

    my ($rcfile, $data) = get_rc_file();

    my $default_sec = delete $data->{default};

    my $download_url = delete $default_sec->{download_server};
    if (!$download_url) {
        err "$rcfile: no download_server specified.\n";
    }

    if ($download_url !~ m{^https?://}) {
        err "$rcfile: the value of download_server must be ",
            "led by https:// or http://.\n";
    }

    my $cache_dir = File::Spec->catdir($ENV{HOME}, ".opm", "cache");
    if (!-d $cache_dir) {
        make_path($cache_dir);
    }

    $download_url =~ s{/+$}{};

    my $header_file = File::Spec->catfile($cache_dir, "last-resp-header");

    my $install_dir = get_install_dir();

    my $lualib_dir = File::Spec->catdir($install_dir, "lualib");
    if (!-d $lualib_dir) {
        make_path $lualib_dir;
    }

    my $pod_dir = File::Spec->catfile($install_dir, "pod");
    if (!-d $pod_dir) {
        make_path $pod_dir;
    }

    my $manifest_dir = File::Spec->catfile($install_dir, "manifest");
    if (!-d $manifest_dir) {
        make_path $manifest_dir;
    }

    my $resty = File::Spec->catfile($install_dir, "bin", "resty");
    if (!-f $resty || !-x $resty) {
        $resty = "resty";  # relying on PATH now
    }

    opendir my $dh, $manifest_dir
        or err "failed to open directory $manifest_dir: $!\n";

    my %installed_files;
    while (my $entry = readdir $dh) {
        next unless $entry =~ /(.+)\.list$/;

        my $pkg_name = $1;
        my $file = File::Spec->catfile($manifest_dir, $entry);

        open my $in, $file
            or die "cannot open $file for reading: $!\n";

        while (<$in>) {
            next unless m{^lualib/};
            chomp;
            #warn "$_ => $pkg_name";
            $installed_files{$_} = $pkg_name;
        }
        close $in;
    }

    closedir $dh
        or err "failed to close directory $manifest_dir: $!\n";

    my $ctx = {
        download_url => $download_url,
        cache_dir => $cache_dir,
        header_file => $header_file,
        install_dir => $install_dir,
        lualib_dir => $lualib_dir,
        pod_dir => $pod_dir,
        manifest_dir => $manifest_dir,
        pkg_installing => {},  # for checking cyclic dependency chain
        installed_files => \%installed_files,  # for clashing files from different pkgs
        level => 0,
        upgrade => $upgrade,
        resty => $resty,
    };

    return $ctx;
}

sub upgrade_target ($$$$) {
    my ($ctx, $account, $name, $meta_file) = @_;

    my $data = read_ini $meta_file;
    my $default_sec = $data->{default};

    my $ver = $default_sec->{version}
        or err "$meta_file: key \"version\" not found.\n";

    my $meta_account = $default_sec->{account}
        or err "$meta_file: key \"account\" not found.\n";

    if ($account && $meta_account ne $account) {
        err "package $account/$name not installed ",
            "(but $meta_account/$name installed).\n";
    }

    my $target = [$meta_account, $name, ">", $ver];

    install_target($ctx, $target);
}

sub do_update {
    my $install_dir = get_install_dir();

    my $manifest_dir = File::Spec->catfile($install_dir, "manifest");
    if (!-d $manifest_dir) {
        return;
    }

    my $ctx = init_installation_ctx(1);

    opendir my $dh, $manifest_dir
        or err "failed to open directory $manifest_dir: $!\n";

    while (my $entry = readdir $dh) {
        #warn $entry;
        if ($entry =~ /(.+)\.meta$/) {
            my $name = $1;

            my $file = File::Spec->catfile($manifest_dir, $entry);

            my $data = read_ini($file);
            my $default_sec = $data->{default};

            my $account = $default_sec->{account}
                or err "$file: no account found for package $name.\n";

            upgrade_target($ctx, $account, $name, $file);
        }
    }

    closedir $dh
        or err "failed to close directory $manifest_dir: $!\n";
}

sub do_search {
    if (@_ == 0) {
        err "no packages specified for search.\n";
    }

    my $query = join " ", @_;

    if (!$query) {
        err "no query specified.\n";
    }

    $query =~ s/\s+/ /g;

    if ($query =~ /[^- .\w]/) {
        err "bad query: $query\n";
    }

    if (length $query > 128) {
        err "query too long: ", length $query, " bytes.\n";
    }

    my ($rcfile, $data) = get_rc_file();

    my $default_sec = delete $data->{default};

    my $download_url = delete $default_sec->{download_server};
    if (!$download_url) {
        err "$rcfile: no download_server specified.\n";
    }

    if ($download_url !~ m{^https?://}) {
        err "$rcfile: the value of download_server must be ",
            "led by https:// or http://.\n";
    }

    (my $escaped_query = $query) =~ s/ /%20/g;

    my $url = "$download_url/api/pkg/search?q=$escaped_query";
    my $out = `curl -i -sS '$url' 2>&1`;
    my $status;
    if ($? == 0 && $out =~ m{^ HTTP/1\.\d \s+ (\d+) \b}ix) {
        $status = $1;

    } else {
        err "failed to search: server error.\n";
    }

    #warn $out;

    $out =~ s/.*?\r?\n\r?\n//s;

    if ($status != 200) {
        err "failed to search on server: status $status: $out\n";
    }

    # TODO highlight hits
    print $out;
}

sub search_pkg_name ($$) {
    my ($ctx, $name) = @_;

    my $download_url = $ctx->{download_url} or die;

    my $url = "$download_url/api/pkg/search/name?q=$name";
    my $out = `curl -i -sS '$url' 2>&1`;
    my $status;
    if ($? == 0 && $out =~ m{^ HTTP/1\.\d \s+ (\d+) \b}ix) {
        $status = $1;

    } else {
        err "failed to find package: server error: $out\n";
    }

    $out =~ s/.*?\r?\n\r?\n//s;

    if ($status != 200) {
        err "failed to find package $name on server: $out";
    }

    print $out;
}

sub test_version_spec ($$$$$) {
    my ($name, $actual_ver, $op, $ver, $source) = @_;

    return if !defined $op || !defined $ver;

    my $rc = cmp_version($actual_ver, $ver);
    #warn "cmp res: $rc";

    if ($op eq '>=') {
        return if $rc >= 0;

    } elsif ($op eq '=') {
        return if $rc == 0;

    } elsif ($op eq '>') {
        return if $rc > 0;
    }

    err "$name $op $ver required but found $name ",
        "$actual_ver according to $source.\n";
}

sub check_utf8_field ($$$) {
    my ($file, $key, $str) = @_;
    eval {
        decode( 'UTF-8', $str, Encode::FB_CROAK )
    };
    if ($@) {
        (my $err = $@) =~ s/ at \S.+? line \d+\.\n?$//;
        err "$file key \"$key\" contains invalid UTF-8 sequences: $err.\n";
    }
}

sub check_user_file_path ($$$$) {
    my ($file, $key, $val, $type) = @_;

    if ($val =~ /\.\./s) {
        err "$file: $key looks malicious since it contains \"..\":  $val";
    }

    if (File::Spec->file_name_is_absolute($val)) {
        err "$file: $key is an absolute path: $val\n";
    }

    if ($type eq 'f') {
        if (!-f $val) {
            err "$file: $key file $val not found.\n";
        }

    } elsif ($type eq 'd') {
        if (!-d $val) {
            err "$file: $key directory $val not found.\n";
        }

    } else {
        err "unknown type: $type\n";
    }
}

sub rebase_path ($$$) {
    my ($a, $a_base, $b_base) = @_;

    my $a_file = realpath($a);
    my $a_dir = realpath($a_base);

    if ($a_file =~ s/^\Q$a_dir\E/$b_base/) {
        return $a_file;
    }

    return undef;
}

sub do_clean {
    my @valid_options = ('dist');
    
    if (@_ == 0) {
        err "no clean option specified.\n";
    }
    
    if ($_[0] eq 'dist') {
        my $dist_file = "dist.ini";
        my $data = read_ini($dist_file);
        my $default_sec = $data->{default};
        my $dist_name = $default_sec->{name};

        opendir(my $dh, './') 
            or err "failed to open directory './'!\n";
            
        my @entities = readdir($dh);
        for my $entity (@entities) {
            
            if (-d $entity) {
                
                if ($entity =~ /^\Q$dist_name\E-[.\w]*\d[.\w]*$/) {
                    shell "rm -rf $entity";
                    print "delete: $entity\n";
                }
            } else {
                
                if ($entity =~ /^\Q$dist_name\E-[.\w]*\d[.\w]*\.tar\.gz$/) {
                    unlink $entity;
                    print "delete: $entity\n";
                }
            }
        }
        closedir $dh
            or err "failed to close directory $dh!\n";
    } else {
        err "unrecognized argument for clean: $_[0]. recognized clean arguments are: " . join(", ", @valid_options);
    }
}

sub err (@) {
    die "ERROR: ", @_;
}

sub shell ($) {
    my $cmd = shift;
    if (system($cmd) != 0) {
        err "failed to run command $cmd\n";
    }
}

sub usage {
    my $rc = shift;

    my $msg = <<_EOC_;
opm [options] command package...

Options:
    -h
    --help              Print this help.

    --cwd               Install into the current working directory under ./resty_modules/
                        instead of the system-wide OpenResty installation tree contaning
                        this tool.

Commands:
    build               Build from the current working directory a package tarball ready
                        for uploading to the server.

    info PACKAGE...     Output the detailed information (or meta data) about the specified
                        packages.  Short package names like "lua-resty-lock" are acceptable.

    get PACKAGE...      Fetch and install the specified packages. Fully qualified package
                        names like "openresty/lua-resty-lock" are required. One can also
                        specify a version constraint like "=0.05" and ">=0.01".

    list                List all the installed packages. Both the package names and versions
                        are displayed.

    remove PACKAGE...   Remove (or uninstall) the specified packages. Short package names
                        like "lua-resty-lock" are acceptable.

    search QUERY...     Search on the server for packages matching the user queries in their
                        names or abstracts. Multiple queries can be specified and they must
                        fulfilled at the same time.

    server-build        Build a final package tarball ready for distribution on the server.
                        This command is usually used by the server to verify the uploaded
                        package tarball.

    update              Update all the installed packages to their latest version from
                        the server.

    upgrade PACKAGE...  Upgrade the packages specified by names to the latest version from
                        the server. Short package names like "lua-resty-lock" are acceptable.

    upload              Upload the package tarball to the server. This command always invokes
                        the build command automatically right before uploading.

For bug reporting instructions, please see:

    <https://openresty.org/en/community.html>

Copyright (C) Yichun Zhang (agentzh). All rights reserved.
_EOC_
    if ($rc == 0) {
        print $msg;
        exit(0);
    }

    warn $msg;
    exit($rc);
}