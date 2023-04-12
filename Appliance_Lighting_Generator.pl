#!/usr/bin/perl
#=================================================================================================================
#   This file is part of Appliance_Lighting_Generator. This is a set of scripts used to generate sub-hourly annual
#   occupancy, and appliance and lighting demand profiles for residential buildings. The subroutines expressed in 
#   this package are adopted from the CREST model developed and distributed by the Centre for Renewable Energy
#   Systems Technology at the University of Loughborough. The subroutines contained in this file are based on the
#   version of CREST described by:
#
#         Richardson, I., Thomson, M., Infield, D., & Clifford, C. (2010). Domestic electricity use: A high-resolution 
#         energy demand model. Energy and buildings, 42(10), 1878-1887.
#
#         For latest developments of the CREST model please see https://repository.lboro.ac.uk/articles/dataset/CREST_Demand_Model_v2_0/2001129
#
# This software is a MODIFICATION and ADAPTATION of the CREST model licensed under the GNU General Public License 
# version 3. This modified software is documented in the publication:
#
#            Wills, A. D., Beausoleil-Morrison, I., & Ugursal, V. I. (2018). Adaptation and validation of an existing 
#            bottom-up model for simulating temporal and inter-dwelling variations of residential appliance and lighting
#            demands. Journal of Building Performance Simulation, 11(3), 350-368.
#
#===========================================================
#   Appliance_Lighting_Generator 
#       Copyright (C) His Majesty the King in Right of Canada, as represented by the National Research Council of Canada, 2023
#       Copyright (C) Centre for Renewable Energy Systems Technology (CREST), Loughborough University, 2020
#
#   Appliance_Lighting_Generator is free software: you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   (at your option) any later version.
#
#   Appliance_Lighting_Generator is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with Appliance_Lighting_Generator.  If not, see <https://www.gnu.org/licenses/>.
#=================================================================================================================
# --------------------------------------------------------------------
# Declare modules which are used
# --------------------------------------------------------------------
# CPAN Modules
use warnings;
use strict;
use XML::Simple; # to parse the XML results files
use Data::Dumper;

# Local Modules
use lib qw(modules);
use OccupancyProfiles;

# INPUTS
my $sInputFile; # Path and filename of input
my $ActStatpth = 'data/activity_stats.csv'; # Appliance activity probabilities
my $ApplianceData = 'data/appliance_database.xml';

# INTERMEDIATES
my @TotalOther;
my @TotalAL;
my $Activity = &ActiveStatParser($ActStatpth);
my $MeanActOcc=0;

# OUTPUTS
my $sOccFile = "Occupancy_Profile.csv";
my $sLightFile = "Aggregate_Lighting_Demand.csv";
my $sAppFile = "Aggregate_Appliance_Demand.csv";
my $sTotal = "Aggregate_App_Lighting_Demand.csv";

# --------------------------------------------------------------------
# Read the command line input arguments
# --------------------------------------------------------------------
if (@ARGV > 1) {die "Only 1 argument required\n";};	# check for proper argument count
$sInputFile = shift @ARGV;

# Parse the input
my $hInput = XMLin($sInputFile);
# Parse the appliance database
my $hApplianceData = XMLin($ApplianceData);

print "\n   Appliance_Lighting_Generator.pl Copyright (C) 2022\n\n";
print "   This program comes with ABSOLUTELY NO WARRANTY\n";
print "   This is free software, and you are welcome to redistribute it\n";
print "   under certain conditions\n\n";

# --------------------------------------------------------------------
# Generate the occupancy profile
# --------------------------------------------------------------------
my $ref_Occ = &getNewOccupancyProfile($hInput->{'inputs'}->{'num_of_occ'}, $hInput->{'sim_parameters'}->{'start_day'});
my @Occ = @$ref_Occ;
open(my $fid, '>', $sOccFile) or die "Could not create output $sOccFile: $!\n";
print $fid "total_occ,$hInput->{'inputs'}->{'num_of_occ'}\n";
print $fid "start_day,$hInput->{'sim_parameters'}->{'start_day'}\n";
print $fid "day_of_year,num_active_occ\n";
my $iHour=1;
foreach my $fActive (@Occ) {
    print $fid "$iHour,$fActive\n";
    $iHour+= (1.0/1440.0);
};
close $fid;
# Determine the mean active occupancy
foreach my $Step (@Occ) {
    if($Step>0) {$MeanActOcc++};
};
$MeanActOcc=$MeanActOcc/($#Occ+1); # Fraction of time occupants are active
print "   Generating active occupant profile complete\n";
print "   - Starting lighting profile\n";
# --------------------------------------------------------------------
# Generate the lighting profile
# --------------------------------------------------------------------
my @Bulbs=(); # Initialize array of household lightbulb wattages
foreach my $val (@{$hInput->{'inputs'}->{'lighting_fixtures'}->{'fixture'}}) {
    push(@Bulbs,$val->{'power'});
};
my $ref_Light = getLightingLoad($hInput->{'inputs'}->{'irr_path'},\@Bulbs,$hInput->{'sim_parameters'}->{'lighting_calibration'},$hInput->{'sim_parameters'}->{'lightning_threshold'}->{'mean'},$hInput->{'sim_parameters'}->{'lightning_threshold'}->{'std_dev'},\@Occ);
my @fLight = @$ref_Light;
open($fid, '>', $sLightFile) or die "Could not create output $sLightFile: $!\n";
print $fid "day_of_year,agg_lighting_W\n";
$iHour=1;
foreach my $fActive (@fLight) {
    my $fActiveWatts = $fActive*1000.0;
    print $fid "$iHour,$fActiveWatts\n";
    $iHour+= (1.0/1440.0);
};
close $fid;
print "      - Lighting profile complete\n";
print "   - Starting appliance profile\n";
# --------------------------------------------------------------------
# Generate the appliance profile
# --------------------------------------------------------------------
# Initialize the appliance demand with unallocated baseload
my $ThisBase = $hInput->{'sim_parameters'}->{'base_load'}; # Constant baseload power [W]
if($ThisBase>0) {
    $ThisBase = getRandomBaseload($ThisBase,$hInput->{'sim_parameters'}->{'base_dev'});
};
if($ThisBase<0) {$ThisBase=0};
@TotalOther = ($ThisBase) x 525600;

# Cold appliances first
if (exists($hInput->{'inputs'}->{'cold_appliances'})) {
     my @hColdApps=();
    
    if(ref($hInput->{'inputs'}->{'cold_appliances'}->{'appliance'}) eq 'ARRAY') {
        push(@hColdApps,@{$hInput->{'inputs'}->{'cold_appliances'}->{'appliance'}});
    } else {
         push(@hColdApps,$hInput->{'inputs'}->{'cold_appliances'}->{'appliance'});
    };
    foreach my $ref (@hColdApps) {
        my $Cold_Ref = &getColdApplianceLoad($ref->{'uec'},$ref->{'base_cycles'},$ref->{'mean_cycle_L'},$ref->{'restart_delay'});
        my @ThisCold = @$Cold_Ref;
    
        # Update the total appliance power draw [W]
        for (my $k=0; $k<=$#ThisCold;$k++) {
            $TotalOther[$k]=$TotalOther[$k]+$ThisCold[$k];
        };
    };
};
# All other appliances
my @ApplianceStock = @{$hInput->{'inputs'}->{'general_appliances'}->{'appliance'}};
foreach my $item (@ApplianceStock) { # For each appliance in the dwelling
    if (not exists($hApplianceData->{$item})) {die "Appliance $item is not defined in $ApplianceData\n";}
    my $App = $hApplianceData->{$item};
    my $ThisApp_ref = &getApplianceProfile(\@Occ,$MeanActOcc,$item,$App,$Activity,$hInput->{'sim_parameters'}->{'appliance_calibration'},$hInput->{'sim_parameters'}->{'start_day'});
    my @ThisApp = @$ThisApp_ref;

    # Update the TotalOther array [W]
    for(my $k=0;$k<=$#TotalOther;$k++) {
        $TotalOther[$k]=$TotalOther[$k]+$ThisApp[$k];
    };
};
print "      - Appliance profile complete\n";
open($fid, '>', $sAppFile) or die "Could not create output $sAppFile: $!\n";
print $fid "day_of_year,agg_appliance_W\n";
$iHour=1;
foreach my $fActive (@TotalOther) {
    print $fid "$iHour,$fActive\n";
    $iHour+= (1.0/1440.0);
};
close $fid;
# --------------------------------------------------------------------
# Get aggregated appliance and lighting loads
# --------------------------------------------------------------------
print "   - Printing out aggregate appliance and lighting loads\n";
foreach (my $i=0;$i<=$#fLight;$i++) {
    my $fSum = $TotalOther[$i]+($fLight[$i]*1000.0);
    push(@TotalAL,$fSum);
};
open($fid, '>', $sTotal) or die "Could not create output $sTotal: $!\n";
print $fid "day_of_year,agg_appliance_light_W\n";
$iHour=1;
foreach my $fActive (@TotalAL) {
    print $fid "$iHour,$fActive\n";
    $iHour+= (1.0/1440.0);
};
close $fid;
print "\n   -- Process complete --\n";