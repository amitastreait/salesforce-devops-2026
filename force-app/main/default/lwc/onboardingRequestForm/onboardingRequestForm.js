import { LightningElement, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import createOnboardingRequest from '@salesforce/apex/OnboardingService.createOnboardingRequest';

const DEPARTMENTS = [
    { label: 'IT',        value: 'IT',        icon: 'utility:desktop' },
    { label: 'HR',        value: 'HR',        icon: 'utility:people'  },
    { label: 'Finance',   value: 'Finance',   icon: 'utility:moneybag'},
    { label: 'Sales',     value: 'Sales',     icon: 'utility:chart'   },
    { label: 'Marketing', value: 'Marketing', icon: 'utility:announce' }
];

const AUTO_TASKS = [
    { label: 'IT Setup',       icon: 'utility:desktop'       },
    { label: 'Facilities',     icon: 'utility:home'          },
    { label: 'HR Paperwork',   icon: 'utility:file'          },
    { label: 'Training',       icon: 'utility:knowledge_base'}
];

export default class OnboardingRequestForm extends NavigationMixin(LightningElement) {

    @track employeeName      = '';
    @track department        = '';
    @track startDate         = '';
    @track isLoading         = false;
    @track errorMessage      = '';
    @track isSuccess         = false;
    @track createdEmployeeName = '';

    _createdRecordId = null;

    // ── Static data ──────────────────────────────────────────────────────

    get autoTaskList() {
        return AUTO_TASKS;
    }

    get departmentOptions() {
        return DEPARTMENTS.map(d => ({
            ...d,
            tileClass: d.value === this.department
                ? 'dept-tile dept-selected'
                : 'dept-tile'
        }));
    }

    get minDate() {
        const d = new Date();
        d.setDate(d.getDate() + 1);
        return d.toISOString().split('T')[0];
    }

    // ── Handlers ─────────────────────────────────────────────────────────

    handleNameChange(event) {
        this.employeeName = event.target.value;
    }

    handleDeptSelect(event) {
        this.department = event.currentTarget.dataset.value;
    }

    handleDateChange(event) {
        this.startDate = event.target.value;
    }

    handleReset() {
        this.employeeName  = '';
        this.department    = '';
        this.startDate     = '';
        this.errorMessage  = '';
    }

    handleCreateAnother() {
        this.isSuccess     = false;
        this.errorMessage  = '';
        this._createdRecordId = null;
        this.createdEmployeeName = '';
        this.handleReset();
    }

    handleViewRecord() {
        if (this._createdRecordId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: this._createdRecordId, actionName: 'view' }
            });
        }
    }

    async handleSubmit() {
        this.errorMessage = '';

        if (!this.employeeName.trim()) {
            this.errorMessage = 'Employee Name is required.';
            return;
        }
        if (!this.department) {
            this.errorMessage = 'Please select a Department.';
            return;
        }
        if (!this.startDate) {
            this.errorMessage = 'Start Date is required.';
            return;
        }

        this.isLoading = true;
        try {
            const recordId = await createOnboardingRequest({
                employeeName : this.employeeName.trim(),
                startDate    : this.startDate,
                department   : this.department
            });
            this._createdRecordId    = recordId;
            this.createdEmployeeName = this.employeeName.trim();
            this.handleReset();
            this.isSuccess = true;
        } catch (error) {
            this.errorMessage = error?.body?.message || 'An unexpected error occurred. Please try again.';
        } finally {
            this.isLoading = false;
        }
    }
}
