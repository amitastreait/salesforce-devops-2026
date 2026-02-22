import { LightningElement, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getAllRequestsWithTasks from '@salesforce/apex/OnboardingService.getAllRequestsWithTasks';
import updateRequestStatus    from '@salesforce/apex/OnboardingService.updateRequestStatus';

const COLUMNS = [
    { label: 'New',         value: 'New',         headerClass: 'col-header h-new'      },
    { label: 'In Progress', value: 'In Progress',  headerClass: 'col-header h-progress' },
    { label: 'Completed',   value: 'Completed',    headerClass: 'col-header h-done'     },
    { label: 'Cancelled',   value: 'Cancelled',    headerClass: 'col-header h-cancel'   }
];

const DEPT_OPTIONS = [
    { label: 'All Departments', value: 'ALL'       },
    { label: 'IT',              value: 'IT'         },
    { label: 'HR',              value: 'HR'         },
    { label: 'Finance',         value: 'Finance'    },
    { label: 'Sales',           value: 'Sales'      },
    { label: 'Marketing',       value: 'Marketing'  }
];

export default class OnboardingKanbanBoard extends LightningElement {

    @track selectedDepartment = 'ALL';
    @track dragOverColumn     = null;
    @track error;

    wiredResult;
    _draggedId     = null;
    _draggedStatus = null;

    // ── Wire ─────────────────────────────────────────────────────────────────

    @wire(getAllRequestsWithTasks)
    wiredRequests(result) {
        this.wiredResult = result;
        if (result.error) {
            this.error = result.error?.body?.message || 'Failed to load requests.';
        }
    }

    // ── Computed ──────────────────────────────────────────────────────────────

    get isLoading() {
        return !this.wiredResult?.data && !this.wiredResult?.error;
    }

    get deptOptions() { return DEPT_OPTIONS; }

    get columns() {
        const allData = this.wiredResult?.data || [];
        const filtered = this.selectedDepartment === 'ALL'
            ? allData
            : allData.filter(r => r.Department__c === this.selectedDepartment);

        return COLUMNS.map(col => {
            const cards = filtered
                .filter(r => r.Status__c === col.value)
                .map(r => ({
                    ...r,
                    assignedHRName : r.Assigned_HR__r?.Name || '—',
                    pct            : r.Completion_Percentage__c ?? 0,
                    taskCount      : (r.Onboarding_Tasks__r || []).length,
                    completedCount : (r.Onboarding_Tasks__r || []).filter(t => t.Is_Completed__c).length
                }));
            return {
                ...col,
                cards,
                count      : cards.length,
                columnClass: `kanban-col${this.dragOverColumn === col.value ? ' drag-over' : ''}`
            };
        });
    }

    // ── Handlers ─────────────────────────────────────────────────────────────

    handleDepartmentFilter(event) {
        this.selectedDepartment = event.detail.value;
    }

    handleDragStart(event) {
        this._draggedId     = event.currentTarget.dataset.id;
        this._draggedStatus = event.currentTarget.dataset.status;
        event.dataTransfer.effectAllowed = 'move';
        event.currentTarget.classList.add('is-dragging');
    }

    handleDragEnd(event) {
        event.currentTarget.classList.remove('is-dragging');
        this.dragOverColumn = null;
    }

    handleDragOver(event) {
        event.preventDefault();
        event.dataTransfer.dropEffect = 'move';
        const col = event.currentTarget.dataset.status;
        if (this.dragOverColumn !== col) this.dragOverColumn = col;
    }

    handleDragLeave(event) {
        if (!event.currentTarget.contains(event.relatedTarget)) {
            this.dragOverColumn = null;
        }
    }

    async handleDrop(event) {
        event.preventDefault();
        const newStatus = event.currentTarget.dataset.status;
        this.dragOverColumn = null;

        if (!this._draggedId || newStatus === this._draggedStatus) return;

        try {
            await updateRequestStatus({ requestId: this._draggedId, newStatus });
            await refreshApex(this.wiredResult);
            this.dispatchEvent(new ShowToastEvent({
                title  : 'Status Updated',
                message: `Moved to ${newStatus}.`,
                variant: 'success'
            }));
        } catch (err) {
            this.dispatchEvent(new ShowToastEvent({
                title  : 'Error',
                message: err?.body?.message || 'Could not update status.',
                variant: 'error'
            }));
        } finally {
            this._draggedId     = null;
            this._draggedStatus = null;
        }
    }

    handleRefresh() {
        refreshApex(this.wiredResult);
    }
}
