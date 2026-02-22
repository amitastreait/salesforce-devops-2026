import { LightningElement, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getAllRequestsWithTasks from '@salesforce/apex/OnboardingService.getAllRequestsWithTasks';
import completeTask from '@salesforce/apex/OnboardingService.completeTask';

const DEPT_OPTIONS = [
    { label: 'All Departments', value: 'ALL'        },
    { label: 'IT',              value: 'IT'          },
    { label: 'HR',              value: 'HR'          },
    { label: 'Finance',         value: 'Finance'     },
    { label: 'Sales',           value: 'Sales'       },
    { label: 'Marketing',       value: 'Marketing'   },
    { label: 'Operations',      value: 'Operations'  }
];

const STATUS_OPTIONS = [
    { label: 'All Statuses',  value: 'ALL'         },
    { label: 'New',           value: 'New'          },
    { label: 'In Progress',   value: 'In Progress'  },
    { label: 'Completed',     value: 'Completed'    },
    { label: 'Cancelled',     value: 'Cancelled'    }
];

const LOCATION_OPTIONS = [
    { label: 'All Locations',  value: 'ALL'           },
    { label: 'New York',       value: 'New York'       },
    { label: 'San Francisco',  value: 'San Francisco'  },
    { label: 'London',         value: 'London'         },
    { label: 'Austin',         value: 'Austin'         },
    { label: 'Chicago',        value: 'Chicago'        },
    { label: 'Toronto',        value: 'Toronto'        },
    { label: 'Remote',         value: 'Remote'         }
];

const WORK_MODE_OPTIONS = [
    { label: 'All Work Modes', value: 'ALL'      },
    { label: 'On-site',        value: 'On-site'  },
    { label: 'Hybrid',         value: 'Hybrid'   },
    { label: 'Remote',         value: 'Remote'   }
];

const STATUS_CLASS = {
    'New'        : 'status-badge s-new',
    'In Progress': 'status-badge s-progress',
    'Completed'  : 'status-badge s-done',
    'Cancelled'  : 'status-badge s-cancel'
};

function workModeBadgeClass(wm) {
    if (wm === 'On-site') return 'wm-badge wm-onsite';
    if (wm === 'Hybrid')  return 'wm-badge wm-hybrid';
    if (wm === 'Remote')  return 'wm-badge wm-remote';
    return '';
}

export default class OnboardingDashboard extends NavigationMixin(LightningElement) {

    @track selectedDepartment = 'ALL';
    @track selectedStatus     = 'ALL';
    @track selectedLocation   = 'ALL';
    @track selectedWorkMode   = 'ALL';
    @track expandedCards      = {};
    @track completingTaskId   = null;
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
                taskIcon    : t.Is_Completed__c ? 'utility:check'  : 'utility:clock',
                iconVariant : t.Is_Completed__c ? 'success'        : 'warning',
                taskClass   : t.Is_Completed__c ? 'task-item done' : 'task-item',
                isCompleting: this.completingTaskId === t.Id
            }));
            const wm = req.Work_Mode__c || '';
            return {
                ...req,
                Completion_Percentage__c : pct,
                assignedHRName      : req.Assigned_HR__r?.Name        || '—',
                reportingManagerName: req.Reporting_Manager__r?.Name  || '',
                buddyName           : req.Buddy__r?.Name              || '',
                jobTitle            : req.Job_Title__c                 || '',
                locationText        : req.Location__c                  || '',
                workModeText        : wm,
                workModeBadgeClass  : workModeBadgeClass(wm),
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
            const deptOk     = this.selectedDepartment === 'ALL' || r.Department__c  === this.selectedDepartment;
            const statusOk   = this.selectedStatus     === 'ALL' || r.Status__c      === this.selectedStatus;
            const locationOk = this.selectedLocation   === 'ALL' || r.Location__c    === this.selectedLocation;
            const workModeOk = this.selectedWorkMode   === 'ALL' || r.Work_Mode__c   === this.selectedWorkMode;
            return deptOk && statusOk && locationOk && workModeOk;
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

    get deptOptions()     { return DEPT_OPTIONS;      }
    get statusOptions()   { return STATUS_OPTIONS;    }
    get locationOptions() { return LOCATION_OPTIONS;  }
    get workModeOptions() { return WORK_MODE_OPTIONS; }

    // ── Handlers ─────────────────────────────────────────────────────────

    handleDepartmentFilter(event) {
        this.selectedDepartment = event.detail.value;
    }

    handleStatusFilter(event) {
        this.selectedStatus = event.detail.value;
    }

    handleLocationFilter(event) {
        this.selectedLocation = event.detail.value;
    }

    handleWorkModeFilter(event) {
        this.selectedWorkMode = event.detail.value;
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

    async handleCompleteTask(event) {
        const taskId = event.currentTarget.dataset.id;
        this.completingTaskId = taskId;
        try {
            await completeTask({ taskId });
            await refreshApex(this.wiredResult);
            this.dispatchEvent(new ShowToastEvent({
                title  : 'Task Complete',
                message: 'Task marked as done.',
                variant: 'success'
            }));
        } catch (err) {
            this.dispatchEvent(new ShowToastEvent({
                title  : 'Error',
                message: err?.body?.message || 'Could not complete task.',
                variant: 'error'
            }));
        } finally {
            this.completingTaskId = null;
        }
    }

    handleRefresh() {
        refreshApex(this.wiredResult);
    }
}
