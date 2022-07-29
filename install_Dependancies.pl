#!/usr/bin/perl
#===========================================================
#   This file is part of the Appliance_Lighting_Generator software. Appliance_Lighting_Generator is
#   free software: you can redistribute it and/or modify it under the terms of the GNU 
#   General Public License as published by the Free Software Foundation, either version 
#   3 of the License, or (at your option) any later version.
#
#   Appliance_Lighting_Generator is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with Appliance_Lighting_Generator.  If not, see <https://www.gnu.org/licenses/>.
#=================================================================================================================
#
#  USAGE: perl install_Dependancies.pl
#
#       This script installs all the required Perl modules for the occupancy and appliance and lighting profile 
#       generator. 
#
# --------------------------------------------------------------------
system('cpan install Data::Dumper');
system('cpan install XML::Simple');