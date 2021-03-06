! This file is part of xtb.
!
! Copyright (C) 2017-2019 Stefan Grimme
!
! xtb is free software: you can redistribute it and/or modify it under
! the terms of the GNU Lesser General Public License as published by
! the Free Software Foundation, either version 3 of the License, or
! (at your option) any later version.
!
! xtb is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
! GNU Lesser General Public License for more details.
!
! You should have received a copy of the GNU Lesser General Public License
! along with xtb.  If not, see <https://www.gnu.org/licenses/>.
submodule(tb_calculators) gfn2_calc_implementation
   implicit none
contains
! ========================================================================
!> GFN2-xTB calculation
module subroutine gfn2_calculation &
      (iunit,env,opt,mol,pcem,wfn,hl_gap,energy,gradient)
   use iso_fortran_env, wp => real64

   use mctc_systools

   use tbdef_options
   use tbdef_molecule
   use tbdef_wavefunction
   use tbdef_basisset
   use tbdef_param
   use tbdef_data
   use tbdef_pcem

   use setparam, only : gfn_method, ngrida
   use aoparam,  only : use_parameterset

   use xbasis
   use eeq_model
   use ncoord
   use scc_core
   use scf_module
   use gbobc
   use embedding

   implicit none

   integer, intent(in) :: iunit

   type(tb_molecule),    intent(inout) :: mol
   type(tb_wavefunction),intent(inout) :: wfn
   type(scc_options),    intent(in)    :: opt
   type(tb_environment), intent(in)    :: env
   type(tb_pcem),        intent(inout) :: pcem

   real(wp), intent(out) :: energy
   real(wp), intent(out) :: hl_gap
   real(wp), intent(out) :: gradient(3,mol%n)

   integer, parameter    :: wsc_rep(3) = [1,1,1] ! FIXME

   type(tb_basisset)     :: basis
   type(scc_parameter)   :: param
   type(scc_results)     :: res
   type(chrg_parameter)  :: chrgeq

   real(wp), allocatable :: cn(:)

   character(len=*),parameter :: outfmt = &
      '(9x,"::",1x,a,f24.12,1x,a,1x,"::")'
   character(len=*), parameter   :: p_fnv_gfn2 = '.param_gfn2.xtb'
   character(len=:), allocatable :: fnv
   real(wp) :: globpar(25)
   integer  :: ipar
   logical  :: exist

   logical  :: okbas

   gfn_method = 2
   call init_pcem

   ! ====================================================================
   !  STEP 1: prepare geometry input
   ! ====================================================================
   ! we assume that the user provides a resonable molecule input
   ! -> all atoms are inside the unit cell, all data is set and consistent

   wfn%nel = nint(sum(mol%z) - mol%chrg)
   wfn%nopen = mol%uhf
   ! at this point, don't complain about odd multiplicities for even electron
   ! systems and just fix it silently, the API is supposed catch this
   if (mod(wfn%nopen,2) == 0.and.mod(wfn%nel,2) /= 0) wfn%nopen = 1
   if (mod(wfn%nopen,2) /= 0.and.mod(wfn%nel,2) == 0) wfn%nopen = 0

   ! give an optional summary on the geometry used
   if (opt%prlevel > 2) then
      call main_geometry(iunit,mol)
   endif

   ! ====================================================================
   !  STEP 2: get the parametrisation
   ! ====================================================================
   ! we could require our user to perform this step, but if we want
   ! to be sure about getting the correct parameters, we should do it here

   ! we will try an internal parameter file first to avoid IO
   call use_parameterset(p_fnv_gfn2,globpar,exist)
   ! no luck, we have to fire up some IO to get our parameters
   if (.not.exist) then
      ! let's check if we can find the parameter file
      call rdpath(env%xtbpath,p_fnv_gfn2,fnv,exist)
      ! maybe the user provides a local parameter file, this was always
      ! an option in `xtb', so we will give it a try
      if (.not.exist) fnv = p_fnv_gfn2
      call open_file(ipar,fnv,'r')
      if (ipar.eq.-1) then
         ! at this point there is no chance to recover from this error
         ! THEREFORE, we have to kill the program
         call raise('E',"Parameter file '"//fnv//"' not found!",1)
         return
      endif
      call read_gfn_param(ipar,globpar,.true.)
      call close_file(ipar)
   endif
   call set_gfn2_parameter(param,globpar,mol%n,mol%at)
   if (opt%prlevel > 1) then
      call gfn2_header(iunit)
      call gfn2_prparam(iunit,mol%n,mol%at,param)
   endif

   lgbsa = len_trim(opt%solvent).gt.0 .and. opt%solvent.ne."none"
   if (lgbsa) then
      call init_gbsa(iunit,trim(opt%solvent),0,opt%etemp,gfn_method,ngrida)
   endif

   ! ====================================================================
   !  STEP 3: expand our Slater basis set in contracted Gaussians
   ! ====================================================================

   call xbasis0(mol%n,mol%at,basis)
   call xbasis_gfn2(mol%n,mol%at,basis,okbas)
   call xbasis_cao2sao(mol%n,mol%at,basis)

   ! ====================================================================
   !  STEP 4: setup the initial wavefunction
   ! ====================================================================

   call wfn%allocate(mol%n,basis%nshell,basis%nao)

   ! do an EEQ guess
   allocate( cn(mol%n), source = 0.0_wp )
   call new_charge_model_2019(chrgeq,mol%n,mol%at)
   call ncoord_erf(mol%n,mol%at,mol%xyz,cn)
   call eeq_chrgeq(mol,chrgeq,cn,wfn%q)
   deallocate(cn)

   call iniqshell(mol%n,mol%at,mol%z,basis%nshell,wfn%q,wfn%qsh,gfn_method)

   if (opt%restart) &
      call read_restart(wfn,'xtbrestart',mol%n,mol%at,gfn_method,exist,.false.)

   ! ====================================================================
   !  STEP 5: do the calculation
   ! ====================================================================
   call scf(iunit,mol,wfn,basis,param,pcem,hl_gap, &
      &     opt%etemp,opt%maxiter,opt%prlevel,.false.,opt%grad,opt%acc, &
      &     energy,gradient,res)

   if (opt%restart) then
      call write_restart(wfn,'xtbrestart',gfn_method)
   endif 

   if (opt%prlevel > 0) then
      write(iunit,'(9x,53(":"))')
      write(iunit,outfmt) "total energy      ", res%e_total,"Eh  "
      write(iunit,outfmt) "gradient norm     ", res%gnorm,  "Eh/α"
      write(iunit,outfmt) "HOMO-LUMO gap     ", res%hl_gap, "eV  "
      write(iunit,'(9x,53(":"))')
   endif

end subroutine gfn2_calculation
end submodule gfn2_calc_implementation
