import { LightningElement, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import getAllRequestsWithTasks from '@salesforce/apex/OnboardingService.getAllRequestsWithTasks';

const DEPT_OPTIONS = [
    { label: 'All Departments', value: 'ALL'       },
    { label: 'IT',              value: 'IT'         },
    { label: 'HR',              value: 'HR'         },
    { label: 'Finance',         value: 'Finance'    },
    { label: 'Sales',           value: 'Sales'      },
    { label: 'Marketing',       value: 'Marketing'  }
];

const STATUS_OPTIONS = [
    { label: 'All Statuses',  value: 'ALL'         },
    { label: 'New',           value: 'New'          },
    { label: 'In Progress',   value: 'In Progress'  },
    { label: 'Completed',     value: 'Completed'    },
    { label: 'Cancelled',     value: 'Cancelled'    }
];

const STATUS_CLASS = {
    'New'        : 'status-badge s-new',
    'In Progress': 'status-badge s-progress',
    'Completed'  : 'status-badge s-done',
    'Cancelled'  : 'status-badge s-cancel'
};

export default class OnboardingDashboard extends NavigationMixin(LightningElement) {

    @track selectedDepartment = 'ALL';
    @track selectedStatus     = 'ALL';
    @track expandedCards      = {};
    @track error;

    wiredResult;

    @wire(getAllRequestsWithTasks)
    wiredRequests(result) {
        this.wiredResult = result;
        if (result.error) {
            this.error = result.error?.body?.message || 'Unknown error';
        }
    }

    // ── Computed: loading / empty ────────────────────────────────────────

    get isLoading() {
        return !this.wiredResult?.data && !this.wiredResult?.error;
    }

    get isEmpty() {
        return !this.isLoading && !this.hasRecords && !this.error;
    }

    get hasRecords() {
        return this.filteredRequests.length > 0;
    }

    // ── Computed: enriched records ───────────────────────────────────────

    get allRequests() {
        if (!this.wiredResult?.data) return [];
        return this.wiredResult.data.map(req => {
            const pct   = req.Completion_Percentage__c ?? 0;
            const tasks = (req.Onboarding_Tasks__r || []).map(t => ({
                ...t,
                taskIcon  : t.Is_Completed__c ? 'utility:check'  : 'utility:clock',
                iconVariant: t.Is_Completed__c ? 'success'        : 'warning',
                taskClass : t.Is_Completed__c ? 'task-item done' : 'task-item'
            }));
            return {
                ...req,
                Completion_Percentage__c : pct,
                assignedHRName  : req.Assigned_HR__r?.Name || '—',
                tasks,
                taskCount       : tasks.length,
                completedCount  : tasks.filter(t => t.Is_Completed__c).length,
                statusClass     : STATUS_CLASS[req.Status__c] || 'status-badge',
                progressVariant : pct === 100 ? 'success' : 'base',
                isExpanded      : !!this.expandedCards[req.Id],
                toggleIcon      : this.expandedCards[req.Id]
                                    ? 'utility:chevrondown'
                                    : 'utility:chevronright'
            };
        });
    }

    get filteredRequests() {
        return this.allRequests.filter(r => {
            const deptOk   = this.selectedDepartment === 'ALL' || r.Department__c === this.selectedDepartment;
            const statusOk = this.selectedStatus     === 'ALL' || r.Status__c     === this.selectedStatus;
            return deptOk && statusOk;
        });
    }

    get filteredCount() { return this.filteredRequests.length; }

    // ── Computed: summary stats ──────────────────────────────────────────

    get summaryStats() {
        const all = this.allRequests;
        return {
            total      : all.length,
            new        : all.filter(r => r.Status__c === 'New').length,
            inProgress : all.filter(r => r.Status__c === 'In Progress').length,
            completed  : all.filter(r => r.Status__c === 'Completed').length,
            cancelled  : all.filter(r => r.Status__c === 'Cancelled').length
        };
    }

    // ── Options ─────────────────────────────────────────────────────────

    get deptOptions()   { return DEPT_OPTIONS;   }
    get statusOptions() { return STATUS_OPTIONS; }

    // ── Handlers ─────────────────────────────────────────────────────────

    handleDepartmentFilter(event) {
        this.selectedDepartment = event.detail.value;
    }

    handleStatusFilter(event) {
        this.selectedStatus = event.detail.value;
    }

    handleToggleTasks(event) {
        const id = event.currentTarget.dataset.id;
        this.expandedCards = { ...this.expandedCards, [id]: !this.expandedCards[id] };
    }

    handleRowClick(event) {
        const recordId = event.currentTarget.dataset.id;
        if (recordId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId, actionName: 'view' }
            });
        }
    }

    handleRefresh() {
        refreshApex(this.wiredResult);
    }
}