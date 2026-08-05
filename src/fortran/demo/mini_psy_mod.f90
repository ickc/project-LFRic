!> @brief The PSy layer, in miniature — written by hand here, generated in LFRic.
!>
!> @details In a real LFRic build nobody writes this file. The algorithm layer
!>          says `call invoke( matvec_kernel_type(lhs, x, op) )`, PSyclone
!>          reads that call together with the kernel's metadata, and emits a
!>          subroutine that looks very much like the one below. What follows is
!>          therefore a *specimen* of generated code: it is worth reading once,
!>          because it makes visible everything the algorithm layer is spared.
!>
!>          Two versions are here, and the difference between them is the point.
!>
!>          `invoke_matvec` is the serial loop over cells.
!>
!>          `invoke_matvec_coloured` does the same work in parallel. It cannot
!>          simply put `!$omp parallel do` on the cell loop: the kernel's access
!>          is `GH_INC`, cells 3 and 4 both increment the dof they share, and
!>          two threads doing that concurrently is a data race — the answer
!>          comes out wrong, quietly and non-deterministically. The fix is to
!>          partition the cells into *colours* such that no two cells of the
!>          same colour share a dof, then run one colour at a time: within a
!>          colour the updates are disjoint, and the barrier between colours
!>          orders the rest.
!>
!>          On this one-dimensional mesh the colouring is odd cells and even
!>          cells. On LFRic's cubed sphere it is computed by a graph-colouring
!>          pass over the mesh, but the argument is identical, and identical
!>          again to the chromatic Gibbs sampler: colour the conflict graph,
!>          then update one independent set at a time.
module mini_psy_mod

  use mini_constants_mod,      only : i_def, r_def
  use mini_field_mod,          only : field_type, field_proxy_type
  use mini_function_space_mod, only : function_space_type
  use mini_matvec_kernel_mod,  only : matvec_code

  implicit none

  private
  public :: invoke_matvec, invoke_matvec_coloured

contains

  !> @brief Serial equivalent of `call invoke( matvec_kernel_type(lhs, x, op) )`.
  !> @param[inout] lhs    Field to increment
  !> @param[in]    x      Field to read
  !> @param[in]    matrix Cell-local operator matrices
  subroutine invoke_matvec(lhs, x, matrix)

    implicit none

    type(field_type), intent(inout) :: lhs
    type(field_type), intent(in)    :: x
    real(r_def),      intent(in)    :: matrix(:,:,:)

    type(field_proxy_type) :: lhs_proxy, x_proxy
    integer(i_def) :: cell, ncell, ndf1, ndf2, undf1, undf2

    ! Step one of every generated PSy routine: unwrap the fields.
    lhs_proxy = lhs%get_proxy()
    x_proxy   = x%get_proxy()

    ncell = lhs_proxy%vspace%get_ncell()
    ndf1  = lhs_proxy%vspace%get_ndf()
    undf1 = lhs_proxy%vspace%get_undf()
    ndf2  = x_proxy%vspace%get_ndf()
    undf2 = x_proxy%vspace%get_undf()

    ! Step two: the loop the algorithm never sees. A halo exchange on `x`
    ! would go here in the distributed-memory case.
    do cell = 1, ncell
      call matvec_code( cell,                                        &
                        lhs_proxy%data, x_proxy%data,                &
                        ncell, matrix,                               &
                        ndf1, undf1, lhs_proxy%vspace%get_cell_dofmap(cell), &
                        ndf2, undf2, x_proxy%vspace%get_cell_dofmap(cell) )
    end do

  end subroutine invoke_matvec

  !> @brief The same invoke, threaded over a two-colouring of the cells.
  !> @param[inout] lhs    Field to increment
  !> @param[in]    x      Field to read
  !> @param[in]    matrix Cell-local operator matrices
  subroutine invoke_matvec_coloured(lhs, x, matrix)

    implicit none

    type(field_type), intent(inout) :: lhs
    type(field_type), intent(in)    :: x
    real(r_def),      intent(in)    :: matrix(:,:,:)

    type(field_proxy_type) :: lhs_proxy, x_proxy
    integer(i_def) :: colour, cell, icell, ncell, ndf1, ndf2, undf1, undf2
    integer(i_def) :: ncolour
    integer(i_def), allocatable :: last_cell_of_colour(:)
    integer(i_def), allocatable :: cmap(:,:)

    lhs_proxy = lhs%get_proxy()
    x_proxy   = x%get_proxy()

    ncell = lhs_proxy%vspace%get_ncell()
    ndf1  = lhs_proxy%vspace%get_ndf()
    undf1 = lhs_proxy%vspace%get_undf()
    ndf2  = x_proxy%vspace%get_ndf()
    undf2 = x_proxy%vspace%get_undf()

    ! LFRic gets `ncolour`, `cmap` and `last_cell_of_colour` from the mesh
    ! object, which computed them once when the mesh was built. Here the
    ! colouring is obvious enough to write down.
    ncolour = 2_i_def
    allocate( cmap(ncolour, (ncell + 1)/2), last_cell_of_colour(ncolour) )
    cmap(:,:) = 0_i_def
    last_cell_of_colour(:) = 0_i_def
    do cell = 1, ncell
      colour = 1_i_def + mod(cell - 1_i_def, 2_i_def)
      last_cell_of_colour(colour) = last_cell_of_colour(colour) + 1_i_def
      cmap(colour, last_cell_of_colour(colour)) = cell
    end do

    ! The generated shape: a serial loop over colours, a parallel loop within.
    ! The implicit barrier at the end of each `!$omp do` is what separates one
    ! colour from the next.
    do colour = 1, ncolour
      !$omp parallel do default(shared), private(icell, cell), schedule(static)
      do icell = 1, last_cell_of_colour(colour)
        cell = cmap(colour, icell)
        call matvec_code( cell,                                        &
                          lhs_proxy%data, x_proxy%data,                &
                          ncell, matrix,                               &
                          ndf1, undf1, lhs_proxy%vspace%get_cell_dofmap(cell), &
                          ndf2, undf2, x_proxy%vspace%get_cell_dofmap(cell) )
      end do
      !$omp end parallel do
    end do

    deallocate( cmap, last_cell_of_colour )

  end subroutine invoke_matvec_coloured

end module mini_psy_mod
