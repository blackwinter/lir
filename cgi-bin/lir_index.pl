#! /usr/bin/perl -T

###############################################################################
#                                                                             #
# lir_index.pl -- Web-frontend for creating indexes for lir.pl.               #
#                                                                             #
# A component of LIR, the experimental information retrieval environment.     #
#                                                                             #
# Copyright (C) 2004-2020 Jens Wille                                          #
#                                                                             #
# LIR is free software: you can redistribute it and/or modify it under the    #
# terms of the GNU Affero General Public License as published by the Free     #
# Software Foundation, either version 3 of the License, or (at your option)   #
# any later version.                                                          #
#                                                                             #
# LIR is distributed in the hope that it will be useful, but WITHOUT ANY      #
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS   #
# FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for     #
# more details.                                                               #
#                                                                             #
# You should have received a copy of the GNU Affero General Public License    #
# along with LIR. If not, see <http://www.gnu.org/licenses/>.                 #
#                                                                             #
###############################################################################

### modules + pragmas

use strict;
use warnings;

use CGI::Carp             qw(fatalsToBrowser warningsToBrowser);
use HTML::Template        qw();
use CGI                   qw(param);

use Encode                qw(from_to);
use File::Spec::Functions qw(catfile);

# My LIR modules
use lib '../lib';

use LIR::GlobalConfig     qw(:vars :cons idx2rec);
use LIR::IndexConfig      qw(:vars);
use LIR::BaseUtil         qw(:subs :cons);

use LIR::CGI;

### /modules + pragmas/

### global variables + settings

# Untaint PATH
$ENV{'PATH'} = '/bin:/usr/bin:/usr/local/bin';

# Make %ENV safer
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

# My indexes
my %records      = ();
my %temp_records = ();
my %index        = ();
my %temp_index   = ();

# My HTML::Template
my $tmpl                   = '';

$ENV{'HTML_TEMPLATE_ROOT'} = $INCLUDES;

my %tmpl_params            = (
  'basename'     => $BASENAME,
  'heading'      => $HEADING,
  'content_type' => $CONTENT_TYPE,
  'cgi_file'     => $CGI_FILE,
  'home_file'    => $HOME_FILE,
  'help_file'    => $HELP_FILE,
  'css_file'     => $CSS_FILE,
  'version'      => $VERSION
);

# global vars

### /global variables + settings/

### action

# Create new CGI object...
my $cgi = LIR::CGI->new(%CGI_DFLTS);

# ...and parse CGI query
$cgi->parse_query;

# Get action to perform
my %action = (
# 'help'    => sub { tmpl_action(); },
  'start'   => sub { start(); },
  'submit'  => sub { submit(); },
  'default' => sub { tmpl_action(); }
);

my $my_action = defined $action{$cgi->action} ? $cgi->action : 'default';

# Perform action
&{$action{$my_action}};

exit 0;

### /action/

### subroutines

# <sub tmpl_action>
# Perform action (input form or help)
sub tmpl_action {
  $my_action = $_[0] if defined $_[0];

  $tmpl = HTML::Template->new('filename'                    => $TMPL{$my_action},
                              'vanguard_compatibility_mode' => 1,
                              'loop_context_vars'           => 1,
                              'global_vars'                 => 1)
    or die "Can't get template for action $my_action!\n";

  $tmpl_params{$my_action} = 1;

  foreach my $r (sort keys %RANKING) {
    next if $r =~ m{\A(?:y|z)\z};
    push(@{$tmpl_params{'input_ranking_files'}} => { 'id'   => $r,
                                                     'name' => $RANKING{$r} });
  }

  $tmpl_params{'seconds'} = $cgi->time;

  # Send output to browser
  print "Content-type: $CONTENT_TYPE\n\n";

  $tmpl->param(%tmpl_params);
  print $tmpl->output;

  warningsToBrowser(1);
}
# </sub tmpl_action>

# <sub start>
# Ask for collection ID
sub start {
  # Parameters and plausibility checks
  my ($missing, $exists) = (0, 0);

  my $collection_id = $cgi->arg('id');
  unless (length $collection_id) {
    $missing++;
    $tmpl_params{'missing_id'}++;
  }
  else {
    $collection_id = untaint_var($collection_id, '\w+');
  }

  my $db_dbm   = $collection_id . '_records.dbm';
  my $db_path  = catfile($LAB_DATA, $db_dbm);
  my $idx_dbm  = $collection_id . '_index.dbm';
  my $idx_path = catfile($LAB_DATA, $idx_dbm);

  my $overwrite = $cgi->arg('overwrite') || '';
  if (-e $db_path || -e $idx_path) {
    if ($overwrite ne $collection_id) {
      $exists++;
      $tmpl_params{'exists_collection'}++;
    }
    else {
      $tmpl_params{'overwrite'} = $overwrite;
    }
  }

  $tmpl_params{'collection_ok'} = ($missing || $exists) ? 0 : 1;

  my $name    = $cgi->arg('name') || $collection_id;
  my $desc    = $cgi->arg('desc') || $name;

  $tmpl_params{'id'}   = $collection_id || '';
  $tmpl_params{'name'} = $name  || '';
  $tmpl_params{'desc'} = $desc  || '';

  tmpl_action('default');
}
# </sub start>

# <sub submit>
# Do the processing
sub submit {
  # Parameters and plausibility checks
  my ($missing, $exists) = (0, 0);
  my %cantread = ( 'db' => 0, 'r' => 0);

  my $collection_id = $cgi->arg('id');
  unless (length $collection_id) {
    $missing++;
    $tmpl_params{'missing_id'}++;
  }
  else {
    $collection_id = untaint_var($collection_id, '\w+');
  }

  my $db_dbm   = $collection_id . '_records.dbm';
  my $db_path  = catfile($LAB_DATA, $db_dbm);
  my $idx_dbm  = $collection_id . '_index.dbm';
  my $idx_path = catfile($LAB_DATA, $idx_dbm);
  my $cfg_dbm  = $collection_id . '_config.dbm';
  my $cfg_path = catfile($LAB_DATA, $cfg_dbm);

  my $name    = $cgi->arg('name') || $collection_id;
  my $desc    = $cgi->arg('desc') || $name;

  my $db_file = $cgi->arg('db_file');
  unless ($db_file) {
    $missing++;
    $tmpl_params{'missing_db_file'}++;
  }
  #$cantread{'db'}++ unless -r $cgi->arg('db_file');

  my $db_enc  = $cgi->arg('db_enc');

  my %r_files   = ();
  foreach my $r (sort keys %RANKING) {
    next if     $r =~ m{\A(?:y|z)\z};
    next unless $cgi->arg("r${r}_file");

    #$cantread{'r'}++ unless -r $cgi->arg("r${r}_file");

    $r_files{$r} = { 'file' => $cgi->arg("r${r}_file"),
                     'enc'  => $cgi->arg("r${r}_enc") };
  }

  unless (%r_files) {
    $missing++;
    $tmpl_params{'missing_r_file'}++;
  }

  $tmpl_params{'cantread_db'} = $cantread{'db'};
  $tmpl_params{'cantread_r'}  = $cantread{'r'};

  my $overwrite = $cgi->arg('overwrite') || '';
  if ((-e $db_path || -e $idx_path) && $overwrite ne $collection_id) {
    $exists++;
    $tmpl_params{'exists_collection'}++;
  }

  $tmpl_params{'id'}   = $collection_id || '';
  $tmpl_params{'name'} = $name  || '';
  $tmpl_params{'desc'} = $desc  || '';

  # Unless something missing/already existing
  unless ($missing || $cantread{'db'} || $cantread{'r'} || $exists) {
    # Categories
    my $cat_id  = $cgi->arg('cat_id')  || '001';
    my $cat_tit = $cgi->arg('cat_tit') || '020';

    # Remove existing files
    unlink $db_path, $idx_path, $cfg_path;

    # Create indexes
    tie_index(\%records, $db_path,  1);
    tie_index(\%index,   $idx_path, 1);

    # Create hash with information on DB
    my %db = ();
    tie_index(\%db, $cfg_path, 1);
    %db = (
      'id'           => $LAB . '/'  . $collection_id,
      'status'       => TRUE,
      'name'         => ucfirst($LAB) . ': ' . $name,
      'info'         => ucfirst($LAB) . ': ' . $desc,
      'db_file'      => catfile($LAB, $db_dbm),
      'idx_file'     => catfile($LAB, $idx_dbm),
      'cat_id'       => $cat_id,
      'cat_tit'      => $cat_tit
    );
    $collection_id = $db{'id'};

    map { $_ = TRUE } @db{keys %RANKING};

    tie_index(\%db);

    # Auxiliary variables
    my %record    = ();
    my %doc_terms = ();
    my $summary   = '';

    # Read in DB
    $summary .= "Processing DB file: $db_file...\n";

    my ($i, $j) = (0, 1);
    my $db_fh   = param('db_file');

    while (my $line = <$db_fh>) {
      $line =~ s{\s*\r?\n}{};
      next unless $line;

      # Record separator: &&&
      unless ($line eq '&&&') {
        $j = 0;
        from_to($line, $db_enc, "utf8");
        $line =~ s{<}{&lt;}g;
        $line =~ s{>}{&gt;}g;
        $line =~ s{&}{&amp;}g;

        #               category:   content
        $line =~ m{\A\s*(.*?)\s*:\s*(.*)\z};
        next unless defined $1 && defined $2;

        $record{$1} = $2;
      }
      else {
        ++$i;
        $j = 1;
        foreach my $key (keys %record) {
          $temp_records{$record{$cat_id}}->{$key} = $record{$key};
        }
        %record = ();
      }

      $summary .= "$i " if $j && $i % 1000 == 0;
    }
    $summary .= "\n$i records read\n";
    close $db_fh;

    unless ($i) {
      unlink $db_path, $idx_path, $cfg_path;
      die "Couldn't read DB file: $db_file!\n";
    }

    my %ranking = %RANKING;
    delete @ranking{qw(x y z)};

    # Read in ranking files
    foreach my $r (sort keys %r_files) {
      delete $ranking{$r};

      my $r_file = $r_files{$r}->{'file'};
      my $r_enc  = $r_files{$r}->{'enc'};

      $summary .= "\nProcessing ranking file: $r_file...\n";

      my ($i, $j) = (0, 1);
      my $r_fh    = param("r${r}_file");

      while (my $line = <$r_fh>) {
        $line =~ s{\s*\r?\n}{};
        next unless $line;

        ++$i;
        from_to($line, $r_enc, 'utf8');

        #                                   id   */;    terms
        my ($id, $terms) = ($line =~ m{\A\s*(.*?)[*;]\s*(.*)\z});
        next unless defined $id && $terms;

        $id     = idx2rec($id);
        $terms .= ';' unless $terms =~ m{[#;]\s*\z};

        #                     term       {weight}#/;
        while ($terms =~ m/\s*(.*?)\s*(?:{(.*?)}\s*)?[#;|]\s*/g) {
          next unless $1;#&& defined $2;

          my $t = $1;

          if (defined $2) {
            my $w = $2;
            $temp_index{$t}->{$id}->{$r} = $w;
            $doc_terms{$id}->{$r}->{$t}  = $w;
          }

          unless ($r_files{'x'}) {
            my $f = freq($t, $id);
            $temp_index{$t}->{$id}->{'x'} = $f;
            $doc_terms{$id}->{'x'}->{$t}  = $f;
          }
        }
        $summary .= "$i " if $j && $i % 1000 == 0;
      }
      $summary .= "\n$i records read\n";

      unless ($i) {
        unlink $db_path, $idx_path, $cfg_path;
        die "Couldn't read ranking file: $r_file!\n";
      }
    }

    # Missing rankings
    if (%ranking) {
      $summary .= "\nCalculating missing rankings...\n";

      # NOTE: [*] Assuming word form == basic form

      my $docNum   = scalar keys %doc_terms;   # docNum | N
      my $colLen   = scalar keys %temp_index;  # colLen [*]
      my %freqW    = ();                       # [freq(W)]
      my %formLenD = ();                       # [formLen(D)]

      foreach my $id (keys %doc_terms) {
        my %term_freqs = %{$doc_terms{$id}->{'x'}};

        foreach my $t (keys %term_freqs) {
          $freqW{$t} += $term_freqs{$t};
          $formLenD{$id}++;
        }
      }

      foreach my $r (sort keys %ranking) {
        $summary .= "- Calculating ranking: $ranking{$r}...\n";

        foreach my $id (keys %doc_terms) {
          my %term_freqs = %{$doc_terms{$id}->{'x'}};

          my $formLenD = $formLenD{$id};  # formLen(D)
          my $docLenD  = $formLenD;       # docLen(D) [*]

          foreach my $t (keys %term_freqs) {
            my $docNumW = scalar keys %{$temp_index{$t}};  # docNum(W) | df
            my $freqWD  = $term_freqs{$t};                 # freq(W, D) | tf
            my $freqW   = $freqW{$t};                      # freq(W)
            my $lenW    = length $t;                       # len(W)
            my $wWD     = undef;                           # w(W, D)

            # Salton
            if ($r eq '0') {
              $wWD = $freqWD * log($docNum / $docNumW);
            }
            # Kascade einfach
            elsif ($r eq '1') {
              my $w1 = 1 - $docNumW / $freqW;
              my $w2 = 1 - (($docLenD / $colLen) / ($freqWD / $freqW));
              $w2 = 0 if $w2 < 0;
              my $w3 = log($lenW) / 4;

              my ($c1, $c2, $c3) = (1, 1, 1);
              $wWD = $c1 * $w1 + $c2 * $w2 + $c3 * $w3;
            }
            # Kascade komplex
            elsif ($r eq '2') {
              my $q = $freqW / $colLen;
              my $p = sub {
                my $i = shift;
                my $j = 1;
                my $k = 1;

                $k *= ++$j while $j < $i;

                return exp(-$q) * $q**$i / $k;
              };

              my $w1 = 1 - $docNumW / $formLenD * (1 - exp(-$q));
              $w1 = 0 if $w1 < 0;
              my $i = 0;
              my $w2 = 0;
              $w2 += $p->(++$i) * $i while $i < $freqWD;
              $w2 /= $q;
              my $w3 = log($lenW) / 4;

              my ($c1, $c2, $c3) = (1, 1, 1);
              $wWD = $c1 * $w1 + $c2 * $w2 + $c3 * $w3;
            }
            # Robertson
            elsif ($r eq '3') {
              my $c = 1.5;  # c ∈ [1.2, 2.0]
              $wWD = ($c + 1) * $freqWD / ($c + $freqWD) * log(($docNum - $docNumW + 0.5) / ($docNumW + 0.5));
            }
            # IDF
            elsif ($r eq '4') {
              $wWD = log($docNum / $docNumW);
            }

            if (defined $wWD) {
              my $w = int($wWD * 10000) / 10000;
              $temp_index{$t}->{$id}->{$r} = $w;
              $doc_terms{$id}->{$r}->{$t}  = $w;
            }
          }
        }
      }
    }

    # Additional entries for index and records
    $summary .= "\nInserting additional entries for index and records...\n";
    my $cat_string = '__%' . $cat_tit . '%__';
    foreach my $doc (keys %doc_terms) {
      $temp_index{$cat_string}->{$doc} = $temp_records{$doc}->{$cat_tit};

      foreach my $r (keys %{$doc_terms{$doc}}) {
        $temp_records{$doc}->{"xx$r"} = \%{$doc_terms{$doc}->{$r}};
      }
    }

    # Create indexes
    $summary .= "\nWriting index files...\n";

    $summary .= "-> $db_path\n";
    %records = %temp_records;

    $summary .= "-> $idx_path\n";
    %index = %temp_index;

    # Change group ID of index files
    chown(-1, $GID, $db_path, $idx_path, $cfg_path);

    $summary .= "...done";

    $tmpl_params{'summary'} = $summary;
    #$tmpl_params{'lir_pl'}  = catfile($CGI_BIN, "$LIR_PL?collection=$collection_id");
    $tmpl_params{'lir_pl'}  = catfile($CGI_BIN, "$LIR_PL?db=$collection_id");
  }

  tmpl_action('default');
}
# </sub submit>

# <sub freq>
# Calculate term frequency
sub freq {
  my ($t, $id) = @_;

  #my $pat = $inv_rvl{$t} || qr{\b($t)\b};
  my $pat = qr{\b($t)\b};
  my $f   = 0;

  foreach my $value (values %{$temp_records{$id}}) {
    while ($value =~ /$pat/g) { $f++; }
  }

  $f ||= 1;  # The term "occurs" at least once

  return $f;
}
# </sub freq>

### /subroutines/

END {
  # Untie indexes
  tie_index(\%records);
  tie_index(\%index);
}
